---
allowed-tools: Bash(hugo server:*), Bash(git status:*), Bash(git checkout -b *), Bash(git add:*), Bash(git commit:*), Bash(cp:*), Bash(mkdir:*), Bash(ls:*), Bash(cat:*)
argument-hint: The blog post markdown file path (e.g., /path/to/post.md).
description: Command for publishing blog posts.
---

## Publishing workflow

When I express satisfaction with the post $1 and request to publish it:

### 1. Preparation & Review
- Read through the post
- Review post using @.claude/post_review_instructions.md guidelines
- If images are inlined using markdown syntax, convert them to Hugo figure shortcodes with absolute paths:
  - Search for `!\[.*\]\(images/.*\)` pattern
  - If mermaid diagrams are not wrapped in `{{< mermaid >}}`, wrap them
- Ensure all images used in the post are present in the post folder
- To identify all image references
- **Critical**: Update image paths from relative to absolute:
  - From: `images/myfolder/image.png`
  - To: `/images/myfolder/image.png`
  - This is required for Hugo to properly locate images

### 2. Repository Setup
- Navigate to `~/projects/blog`
- Check `git status` to understand current state
- **Always** Create a new feature branch from main:
  - Branch name format: `blog/[series-name]-post-[xx]-[topic]` or `blog/[topic-name]` for standalone posts
  - Example: `blog/mcp-series-post-01-problem` or `blog/mcp-overview`

### 3. Create Post Structure
- Create new folder under `content/posts/` following this naming:
  - **Series post**: `series-name-xx-topic` (e.g., `mcp-series-01-problem`)
  - **Standalone post**: `topic-name` (e.g., `mcp-overview`)
  - Use dashes instead of spaces
- Copy post markdown file to this folder as `index.md`

### 4. Add Images to Assets
- Create organized subdirectory in `assets/images/`:
  - Example: `assets/images/mcp/`
- Copy all images from source folder to assets subdirectory
- Verify images are properly referenced with absolute paths

### 5. Verification
- Run `hugo server` to check for build errors
- Note: Theme shortcode errors unrelated to our content are acceptable
- Ensure our new content doesn't introduce errors

### 6. Commit Changes
- Stage all new files with `git add -A`
- Create commit with descriptive message:
  - Format: "Add [Series]: [Post Title]"
  - Example: "Add MCP blog series post 1: The Problem MCP Solves"
- Verify commit success

### 7. Final Status
- Notify me the post is ready
- Report any non-blocking theme issues observed 
---
*End of document*