# Blog Project Documentation

## Project Overview

This is a Hugo static site blog using the **Blowfish** theme. The site focuses on technical content.

**Theme**: Blowfish (https://github.com/nunocoracao/blowfish)
**Hugo Version**: v0.153.2+extended+withdeploy

## Project Structure

```
blog/
├── archetypes/          # Content templates
├── assets/              # Images and other assets
├── config/_default/     # Hugo configuration files
│   ├── hugo.toml       # Main config
│   ├── languages.en.toml
│   ├── markup.toml
│   ├── menus.en.toml
│   ├── module.toml
│   └── params.toml
├── content/             # Content files
│   ├── about/          # About page
│   └── posts/          # Blog posts
├── layouts/             # Custom layouts (overrides theme)
│   └── shortcodes/     # Custom shortcodes
├── static/              # Static files
├── themes/              # Hugo themes
│   └── blowfish/       # Blowfish theme
└── public/              # Generated site output
```

## Custom Shortcodes

### `shell`
Located at `layouts/shortcodes/shell.html`, this shortcode creates styled shell command blocks with syntax highlighting and a "sh" badge that appears on hover.

**Usage**:
```markdown
{{< shell >}}
hugo server
{{< /shell >}}
```

**Features**:
- Syntax highlighting for bash/shell commands
- Hover-to-show "sh" badge in top-right corner
- Responsive design with dark mode support

## Commands

### Development
```bash
# Start development server with live reload
hugo server

# Or with full rebuilds on change
hugo server --disableFastRender

# Server runs at http://localhost:1313/
```

### Building
```bash
# Build the site (output in public/)
hugo

# Build for production with minification
hugo --minify
```

### Content Creation
```bash
# Create a new post
hugo new posts/my-post/index.md

# Create about page
hugo new about/index.md
```

## Configuration

### Main Configuration (hugo.toml)
Located at `config/_default/hugo.toml`

### Theme Parameters (params.toml)
Located at `config/_default/params.toml`

### Menu Configuration
Located at `config/_default/menus.en.toml`

## Theme Documentation

Blowfish theme documentation: https://blowfish.page/

Key features used:
- Light/dark mode toggle
- Post series navigation
- Figure shortcodes
- Code highlighting with Chroma
- Responsive design


## Troubleshooting

### Server Won't Start
If you encounter errors:
1. Run `hugo server` to see line-specific error messages

### UI Issues
If UI elements don't render correctly:
1. Run `hugo server --disableFastRender`
2. Open Playwright using playwright MCP server tools and verify UI components
3. Check browser console for errors
4. Then based on your findinhgs, fix the relevant part of the codebase.


## Notes

- The site uses Hugo modules to manage the Blowfish theme
- Custom shortcodes should go in `layouts/shortcodes/`
- Custom CSS should go in `assets/css/`
- Images should go in `assets/images/`
- **Never** edit the `themes` directory directly.