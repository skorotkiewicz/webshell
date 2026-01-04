#!/usr/bin/python

import os
import sys
import time
import json
import curses
from pathlib import Path

# Config
SOCIAL_DIR = Path("/var/social")
POSTS_DIR = SOCIAL_DIR / "posts"
USERS_FILE = SOCIAL_DIR / "users.json"
USER = os.getenv("USER", "unknown")

# Ensure storage exists with proper permissions
# Set umask to 0 so files are created with full permissions
old_umask = os.umask(0)

SOCIAL_DIR.mkdir(parents=True, exist_ok=True, mode=0o1777)
POSTS_DIR.mkdir(parents=True, exist_ok=True, mode=0o1777)
if not USERS_FILE.exists():
    USERS_FILE.write_text(json.dumps([]))
    os.chmod(USERS_FILE, 0o666)

os.umask(old_umask)

# Helper functions
def load_users():
    try:
        with USERS_FILE.open() as f:
            return json.load(f)
    except (PermissionError, json.JSONDecodeError):
        return []

def save_users(users):
    try:
        with USERS_FILE.open("w") as f:
            json.dump(users, f, indent=2)
    except PermissionError:
        pass  # Can't write to file owned by another user

def register_user(user):
    users = load_users()
    if user not in users:
        users.append(user)
        save_users(users)

def get_post_files():
    # Sort posts by timestamp, newest to oldest
    post_files = sorted(POSTS_DIR.glob("*.json"), key=lambda p: load_post(p)["timestamp"], reverse=True)
    return post_files

def load_post(file):
    with file.open() as f:
        return json.load(f)

def save_post(post, post_id=None):
    is_new = post_id is None
    if is_new:
        # Calculate next PostID based on the number of posts
        post_files = get_post_files()
        post_id = str(len(post_files) + 1)
        post["id"] = post_id
    else:
        post["id"] = post_id

    post_file = POSTS_DIR / f"{post_id}.json"
    with post_file.open("w") as f:
        json.dump(post, f, indent=2)
    
    # Only chmod new files we created
    if is_new:
        try:
            os.chmod(post_file, 0o666)
        except PermissionError:
            pass
    return post_id

def get_post_by_id(post_id):
    for post_file in get_post_files():
        post = load_post(post_file)
        if post.get("id") == post_id:
            return post_file
    return None

def create_post(screen):
    curses.echo()
    screen.addstr("What's happening? ")
    text = screen.getstr().decode()
    curses.noecho()
    post = {"user": USER, "text": text, "likes": 0, "reposts": 0, "comments": [], "timestamp": time.time()}
    save_post(post)

def like_post(screen, posts):
    curses.echo()
    screen.addstr("Enter PostID to like: ")
    post_id = screen.getstr().decode().strip()  # Get the PostID as string
    curses.noecho()
    post_file = get_post_by_id(post_id)
    if post_file:
        post = load_post(post_file)
        post["likes"] += 1
        save_post(post, post_id)
    else:
        screen.addstr("Invalid PostID\n")
        screen.getch()

def repost_post(screen, posts):
    curses.echo()
    screen.addstr("Enter PostID to repost: ")
    post_id = screen.getstr().decode().strip()  # Get the PostID as string
    curses.noecho()
    post_file = get_post_by_id(post_id)
    if post_file:
        orig = load_post(post_file)
        orig["reposts"] += 1
        save_post(orig, post_file.stem)

        repost = {"user": USER, "text": f"[Repost] {orig['text']}", "likes": 0, "reposts": 0, "comments": [], "timestamp": time.time()}
        save_post(repost)
    else:
        screen.addstr("Invalid PostID\n")
        screen.getch()

def comment_post(screen, posts):
    curses.echo()
    screen.addstr("Enter PostID to comment on: ")
    post_id = screen.getstr().decode().strip()  # Get the PostID as string
    screen.addstr("Enter your comment: ")
    comment_text = screen.getstr().decode().strip()
    curses.noecho()
    
    post_file = get_post_by_id(post_id)
    if post_file:
        post = load_post(post_file)
        post["comments"].append({"user": USER, "text": comment_text, "timestamp": time.time()})
        save_post(post, post_file.stem)
    else:
        screen.addstr("Invalid PostID\n")
        screen.getch()

def delete_post(screen, posts):
    curses.echo()
    screen.addstr("Enter PostID to delete: ")
    post_id = screen.getstr().decode().strip()  # Get the PostID as string
    curses.noecho()
    post_file = get_post_by_id(post_id)
    if post_file:
        post = load_post(post_file)
        if post["user"] == USER:
            post_file.unlink()
        else:
            screen.addstr("Cannot delete others' posts!\n")
            screen.getch()
    else:
        screen.addstr("Invalid PostID\n")
        screen.getch()

def view_post(screen, posts):
    curses.echo()
    screen.addstr("Enter PostID to view: ")
    post_id = screen.getstr().decode().strip()  # Get the PostID as string
    curses.noecho()
    
    post_file = get_post_by_id(post_id)
    if post_file:
        post = load_post(post_file)

        screen.clear()
        screen.addstr(f"PostID: {post.get('id', post_file.stem)}\n")
        screen.addstr(f"Post by: {post['user']}\n")
        screen.addstr(f"Text: {post['text']}\n")
        screen.addstr(f"❤ {post['likes']}   🔄 {post['reposts']}   Comments: {len(post['comments'])}\n")
        
        # Display time of post
        screen.addstr(f"Posted on: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(post['timestamp']))}\n")
        
        screen.addstr("\nComments:\n")
        for comment in post["comments"]:
            screen.addstr(f"- {comment['user']}: {comment['text']}\n")
            # Display time of comment
            screen.addstr(f"   Commented on: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(comment['timestamp']))}\n")

        screen.addstr("\nPress any key to return...")
        screen.getch()
    else:
        screen.addstr("Invalid PostID\n")
        screen.getch()

def view_users(screen):
    screen.clear()
    users = load_users()
    screen.addstr("Registered Users:\n")
    for user in users:
        screen.addstr(f"- {user}\n")
    screen.addstr("\nPress any key to return...")
    screen.getch()

def wrap_text(text, width):
    lines = []
    while len(text) > width:
        line = text[:width]
        lines.append(line)
        text = text[width:]
    if text:
        lines.append(text)
    return lines

def render_feed(screen, posts, start_idx):
    screen.clear()
    screen.addstr(f"🐧 Local Social - User: {USER}\n")
    screen.addstr("PostID        | User      | Post                                   | ❤ | 🔄 | Comments\n")
    screen.addstr("-" * 100 + "\n")
    
    # Get terminal size to avoid overflow
    height, width = screen.getmaxyx()
    max_lines = min(10, height - 2)  # Limit the number of lines to 10, reserve space for header and footer

    # Display posts in the range from start_idx
    posts_to_display = posts[start_idx:start_idx + max_lines]
    for post_file in posts_to_display:
        post = load_post(post_file)

        # Wrap text to fit the screen
        wrapped_text = wrap_text(post['text'], width - 60)
        screen.addstr(f"{post['id']:<13}| {post['user']:<10}| {wrapped_text[0]:<38}| {post['likes']:<3}| {post['reposts']:<3}| {len(post['comments'])}\n")
        for line in wrapped_text[1:]:
            screen.addstr(f"{'':<13}| {'':<10}| {'':<38}| {'':<3}| {'':<3}| {'':<2}\n")
            screen.addstr(f"{'':<13}| {'':<10}| {line:<38}\n")

    screen.addstr("\n")

def main_menu(screen):
    register_user(USER)

    start_idx = 0  # Index of the first post to display

    while True:
        posts = get_post_files()
        render_feed(screen, posts, start_idx)

        screen.addstr("Options: [n] New Post | [l] Like | [r] Repost | [c] Comment | [v] View Post | [d] Delete | [u] Users | [q] Quit\n")
        choice = screen.getkey()

        if choice == "n":
            create_post(screen)
        elif choice == "l":
            like_post(screen, posts)
        elif choice == "r":
            repost_post(screen, posts)
        elif choice == "c":
            comment_post(screen, posts)
        elif choice == "v":
            view_post(screen, posts)
        elif choice == "d":
            delete_post(screen, posts)
        elif choice == "u":
            view_users(screen)
        elif choice == "q":
            break
        elif choice == "k" and start_idx > 0:
            start_idx -= 10  # Scroll up by 10 posts
        elif choice == "j" and start_idx + 10 < len(posts):
            start_idx += 10  # Scroll down by 10 posts

if __name__ == "__main__":
    curses.wrapper(main_menu)