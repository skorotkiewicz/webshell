#!/usr/bin/env python3
"""A local feed backed by small, owner-checked records."""
import curses
import json
import os
import pwd
import stat
import sys
import textwrap
import time
import uuid
from pathlib import Path

SOCIAL_DIR = Path('/var/social/users')
MAX_TEXT = 1000
MAX_RECORD = 8192
KINDS = {'post', 'like', 'comment', 'delete'}


def clean(text):
    return ''.join(char if char.isprintable() else ' ' for char in text)


class Store:
    def __init__(self, root=SOCIAL_DIR):
        self.root = Path(root)
        self.uid = os.getuid()
        self.user = pwd.getpwuid(self.uid).pw_name

    def records(self):
        # shortcut: scan the small feed each refresh; use an indexed service if it outgrows session RAM.
        records = []
        for directory in self.root.iterdir():
            try:
                owner = pwd.getpwnam(directory.name)
                fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            except (KeyError, OSError):
                continue
            try:
                if os.fstat(fd).st_uid != owner.pw_uid:
                    continue
                for name in os.listdir(fd):
                    if not name.endswith('.json'):
                        continue
                    try:
                        record_id = str(uuid.UUID(name[:-5]))
                        if name != record_id + '.json':
                            continue
                        file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                        with os.fdopen(file_fd, 'rb') as file:
                            info = os.fstat(file.fileno())
                            if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner.pw_uid
                                    or info.st_mode & 0o022):
                                continue
                            data = file.read(MAX_RECORD + 1)
                        if len(data) > MAX_RECORD:
                            continue
                        record = json.loads(data)
                        if not isinstance(record, dict) or record.get('kind') not in KINDS:
                            continue
                        if not isinstance(record.get('text', ''), str) or len(record.get('text', '')) > MAX_TEXT:
                            continue
                        if record['kind'] != 'post' and not isinstance(record.get('target'), str):
                            continue
                        # File ownership, not JSON or $USER, determines authorship.
                        record.update(id=record_id, user=owner.pw_name, uid=owner.pw_uid,
                                      timestamp=info.st_mtime)
                        records.append(record)
                    except (OSError, ValueError, TypeError, RecursionError):
                        continue
            finally:
                os.close(fd)
        return sorted(records, key=lambda record: (record['timestamp'], record['id']))

    def feed(self):
        records = self.records()
        posts = {record['id']: dict(record, likes=set(), comments=[])
                 for record in records if record['kind'] == 'post'}
        deleted = set()
        for record in records:
            if record['kind'] == 'post':
                continue
            post = posts.get(record.get('target'))
            if post is None:
                continue
            if record['kind'] == 'delete' and record['uid'] == post['uid']:
                deleted.add(post['id'])
            elif record['kind'] == 'like':
                post['likes'].add(record['uid'])
            elif record['kind'] == 'comment':
                post['comments'].append(record)
        return sorted((post for key, post in posts.items() if key not in deleted),
                      key=lambda post: (post['timestamp'], post['id']), reverse=True)

    def write(self, kind, text='', target=None):
        text = text.strip()
        if kind not in KINDS or len(text) > MAX_TEXT:
            raise ValueError('Invalid action or text longer than 1000 characters.')
        if kind in {'post', 'comment'} and not text:
            raise ValueError('Text cannot be empty.')
        if kind != 'post':
            post = next((post for post in self.feed() if post['id'] == target), None)
            if post is None:
                raise ValueError('Post no longer exists. Refresh the feed.')
            if kind == 'delete' and post['uid'] != self.uid:
                raise ValueError('You can only hide your own posts.')
        data = json.dumps({'kind': kind, 'text': text, 'target': target}, ensure_ascii=False).encode('utf-8')
        if len(data) > MAX_RECORD:
            raise ValueError('Text is too large.')
        record_id = str(uuid.uuid4())
        fd = os.open(self.root / self.user, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != self.uid:
                raise PermissionError('Your social directory has the wrong owner.')
            temporary = record_id + '.tmp'
            file_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o644, dir_fd=fd)
            with os.fdopen(file_fd, 'wb') as file:
                os.fchmod(file.fileno(), 0o644)
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            os.rename(temporary, record_id + '.json', src_dir_fd=fd, dst_dir_fd=fd)
            os.fsync(fd)
        finally:
            os.close(fd)
        return record_id


def put(screen, row, text):
    height, width = screen.getmaxyx()
    if 0 <= row < height and width > 1:
        try:
            screen.addnstr(row, 0, clean(text), width - 1)
        except curses.error:
            pass  # A resize or wide Unicode can exceed the last column.


def ask(screen, prompt):
    height, width = screen.getmaxyx()
    if height < 3 or width < 12:
        raise ValueError('Enlarge the terminal to enter text.')
    screen.move(height - 2, 0)
    screen.clrtoeol()
    put(screen, height - 2, prompt)
    screen.move(height - 1, 0)
    screen.clrtoeol()
    curses.echo()
    try:
        return screen.getstr(MAX_TEXT * 4).decode('utf-8', errors='replace').strip()
    finally:
        curses.noecho()


def view(screen, post):
    _, width = screen.getmaxyx()
    lines = [f"{post['user']} | {len(post['likes'])} likes",
             time.strftime('%Y-%m-%d %H:%M', time.localtime(post['timestamp'])), '']
    lines.extend(textwrap.wrap(clean(post['text']), max(1, width - 1)))
    lines.append('Comments')
    for comment in post['comments']:
        lines.extend(textwrap.wrap(f"{comment['user']}: {clean(comment['text'])}", max(1, width - 1)))
    offset = 0
    while True:
        screen.erase()
        height, _ = screen.getmaxyx()
        page = max(1, height - 1)
        for row, line in enumerate(lines[offset:offset + page]):
            put(screen, row, line)
        put(screen, height - 1, 'j/k scroll | q back')
        key = screen.getch()
        if key in (ord('q'), 27):
            return
        if key in (ord('j'), curses.KEY_DOWN):
            offset = min(max(0, len(lines) - page), offset + 1)
        elif key in (ord('k'), curses.KEY_UP):
            offset = max(0, offset - 1)


def main_menu(screen, store):
    screen.keypad(True)
    selected = 0
    message = ''
    while True:
        posts = store.feed()
        selected = min(selected, max(0, len(posts) - 1))
        height, _ = screen.getmaxyx()
        screen.erase()
        put(screen, 0, f'Local social | {store.user} | {len(posts)} posts')
        page = max(1, (height - 4) // 2)
        start = selected // page * page
        for index in range(start, min(start + page, len(posts))):
            post = posts[index]
            row = 1 + (index - start) * 2
            put(screen, row, f"{'>' if index == selected else ' '} {post['user']} | "
                f"{len(post['likes'])} likes | {len(post['comments'])} comments")
            put(screen, row + 1, '  ' + post['text'])
        if not posts:
            put(screen, 1, 'No posts yet. Press n to write one.')
        put(screen, height - 2, message)
        put(screen, height - 1, 'j/k move n post l like c comment r repost v view d hide q quit')
        key = screen.getch()
        message = ''
        try:
            if key == ord('q'):
                return
            if key in (ord('j'), curses.KEY_DOWN):
                selected = min(selected + 1, max(0, len(posts) - 1))
            elif key in (ord('k'), curses.KEY_UP):
                selected = max(0, selected - 1)
            elif key == ord('n'):
                store.write('post', ask(screen, 'New post:'))
                selected = 0
            elif posts:
                post = posts[selected]
                if key == ord('l'):
                    store.write('like', target=post['id'])
                elif key == ord('c'):
                    store.write('comment', ask(screen, 'Comment:'), post['id'])
                elif key == ord('r'):
                    store.write('post', f"[Repost {post['user']}] {post['text']}"[:MAX_TEXT])
                    selected = 0
                elif key == ord('v'):
                    view(screen, post)
                elif key == ord('d') and ask(screen, 'Hide this post? Type yes:') == 'yes':
                    store.write('delete', target=post['id'])
        except (OSError, ValueError, curses.error) as error:
            message = str(error)


def main():
    try:
        curses.wrapper(main_menu, Store())
    except (OSError, curses.error) as error:
        print(f'social: {error}. Log in through WebShell to provision storage.', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
