# zig-gitweb

A fast web frontend for git repositories, implemented in Zig. This is
implemented as a lightweight CGI application for browsing git repositories
through a web interface.

## Features

- 📊 Repository summary with recent commits, branches, and tags
- 📜 Commit log with pagination
- 🌳 Tree/file browser with syntax highlighting
- 🔍 Commit diff viewer
- 📦 Snapshot downloads (tar.gz, zip)
- 🏷️ Tag and branch browsing
- ⚡ Fast and lightweight CGI application
- 🔧 Written in Zig for performance and safety

## Requirements

- Zig 0.15.1 or later
- libgit2
- zlib

## Installation

### macOS (Homebrew)

```bash
brew install libgit2
```

### Linux (Debian/Ubuntu)

```bash
sudo apt-get install libgit2-dev zlib1g-dev
```

### Build from Source

```bash
git clone https://github.com/mrjbq7/zig-gitweb.git
cd zig-gitweb
zig build
```

This will create `gitweb.cgi` in `zig-out/bin/`.

## Usage

### As a CGI Application

Configure your web server to execute `gitweb.cgi` as a CGI script. The
application reads repository locations from a configuration file.

#### Apache Configuration Example

```apache
ScriptAlias /git "/path/to/gitweb.cgi"
<Directory "/path/to">
    Options ExecCGI
    AddHandler cgi-script .cgi
    Require all granted
</Directory>
```

#### Nginx Configuration Example (with fcgiwrap)

```nginx
server {
    listen 80;
    server_name zig-gitweb;
    root /zig-gitweb;

    # Index redirects to cgi
    location = / { rewrite ^ /cgi-bin/gitweb.cgi last; }

    # Try and load static files
    location / { try_files $uri $uri/ @gitweb; }

    # Otherwise forward to the cgi
    location @gitweb { rewrite ^ /cgi-bin/gitweb.cgi?url=$uri&$args last; }

    # Allow only *.cgi to execute
    location ~ ^/cgi-bin/(.+\.cgi)$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/cgi-bin/$1;
        fastcgi_param SCRIPT_NAME     /cgi-bin/$1;
        fastcgi_param PATH_INFO       "";
        fastcgi_pass unix:/run/fcgiwrap.socket;
    }

    # Everything else under /cgi-bin is blocked (prefix location has lower prio than regex)
    location /cgi-bin/ { return 404; }
}
```

#### Factor Configuration Example

You can use [Factor](https://factorcode.org) to serve this also:

```factor
TUPLE: zig-gitweb < file-responder ;

: <zig-gitweb> ( root -- responder )
    zig-gitweb new
        swap >>root
        [ (serve-static) ] >>hook
        H{ } clone >>special
    enable-cgi ;

M: zig-gitweb call-responder*
    dup file-responder set
    over [ f ] [ "/" join serving-path file-exists? ] if-empty [
        url get
            rot "/" join "url" set-query-param
            "gitweb.cgi" >>path drop { "gitweb.cgi" } swap
    ] unless call-next-method ;
```

### Testing Locally

```bash
# Create a test repository
mkdir -p /tmp/git
git init --bare /tmp/git/myproject.git

# Create a minimal configuration
echo "scan-path=/tmp/git" > /tmp/gitweb.conf

# Test the CGI directly
GITWEB_CONFIG=/tmp/gitweb.conf QUERY_STRING="r=myproject" REQUEST_METHOD=GET ./zig-out/bin/gitweb.cgi
```

### URL Parameters

- `r` - Repository name (e.g., `?r=myproject`)
- `cmd` - Command/page to display:
  - `summary` - Repository overview (default)
  - `log` - Commit history
  - `tree` - File browser
  - `commit` - Commit details
  - `diff` - Commit differences
  - `refs` - Branches and tags
  - `snapshot` - Download archive
- `id` - Commit/tree/tag ID
- `path` - File or directory path
- `h` - Branch/tag reference

### Example URLs

- `/git?r=myproject` - Repository summary
- `/git?r=myproject&cmd=log` - Commit log
- `/git?r=myproject&cmd=tree` - Browse files
- `/git?r=myproject&cmd=commit&id=abc123` - View specific commit
- `/git?r=myproject&cmd=snapshot&h=main&fmt=tar.gz` - Download tarball

## Configuration

### Configuration File

zig-gitweb uses a configuration file (gitweb.conf) to specify repository locations and settings.
The configuration file is read from:
1. The path specified in the `GITWEB_CONFIG` environment variable
2. `/etc/gitweb.conf` (default location)

See `gitweb.conf.example` for a complete example configuration.

### Repository Setup

There are several ways to configure repositories:

#### 1. Automatic scanning with scan-path

```ini
# In gitweb.conf:
scan-path=/srv/git
```

All bare git repositories under `/srv/git` will be automatically discovered.

#### 2. Manual repository configuration

```ini
# In gitweb.conf:
repo.url=myproject
repo.path=/path/to/myproject.git
repo.desc=My Project Description
repo.owner=John Doe
```

#### 3. Project list file

```ini
# In gitweb.conf:
project-list=/etc/gitweb-projects.txt
```

Where the project list file contains repository paths, one per line.

### Example: Setting up repositories

```bash
# Create a directory for git repositories
sudo mkdir -p /srv/git
sudo chown $USER:$USER /srv/git

# Create a bare repository
git init --bare /srv/git/myproject.git

# Push an existing project
cd /path/to/existing/project
git remote add web /srv/git/myproject.git
git push web main

# Configure gitweb.conf
sudo tee /etc/gitweb.conf <<EOF
scan-path=/srv/git
root-title=My Git Repositories
root-desc=Source code repository browser
EOF
```

### Customization

Static files are located in the `static/` directory:
- `gitweb.css` - Stylesheet customization
- `gitweb.js` - JavaScript enhancements

## Development

### Building

```bash
zig build                 # Build the project
zig build test            # Run tests
zig build --release=fast  # Build optimized version
```

### Project Structure

```
zig-gitweb/
├── src/
│   ├── main.zig       # CGI entry point
│   ├── gitweb.zig     # Core types and configuration
│   ├── git.zig        # libgit2 wrapper
│   ├── cmd.zig        # Command dispatcher
│   ├── html.zig       # HTML generation utilities
│   └── ui/            # UI handlers for each command
│       ├── log.zig
│       ├── commit.zig
│       ├── tree.zig
│       └── ...
├── static/            # CSS, JS, and other static files
├── build.zig          # Build configuration
└── build.zig.zon      # Package manifest
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Acknowledgments

This project is inspired by [cgit](https://git.zx2c4.com/cgit/), but freshly
implemented in [Zig](https://ziglang.org). It currently uses
[libgit2](https://libgit2.org/) for git repository access, and
[zlib](https://zlib.net/) for compression.
