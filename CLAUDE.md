# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **zig-gitweb** (formerly zgit), a web frontend for git repositories implemented in Zig. It's a port of cgit to Zig 0.15.1, designed to run as a CGI application that provides a fast web interface for browsing git repositories.

## Build Commands

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the CGI directly (requires CGI environment variables)
QUERY_STRING="r=repo_name" REQUEST_METHOD=GET ./zig-out/bin/gitweb.cgi

# Test with a specific repository (example with factor.git)
QUERY_STRING="r=factor" REQUEST_METHOD=GET ./zig-out/bin/gitweb.cgi
```

## Architecture

### Core Components

1. **CGI Entry Point** (`src/main.zig`)
   - Initializes libgit2
   - Processes CGI environment variables
   - Routes requests through the command dispatcher

2. **Context System** (`src/gitweb.zig`)
   - Central `Context` struct holds configuration, repository info, and request state
   - `Repo` struct represents repository configuration
   - All UI handlers receive context for rendering

3. **Git Wrapper** (`src/git.zig`)
   - Wraps libgit2 C API with Zig-friendly interfaces
   - Provides Repository, Commit, Tree, Blob, Diff types
   - Handles OID conversions and memory management
   - **Important**: Exports `pub const c` for shared libgit2 imports (prevents type mismatch issues)

4. **Command Dispatcher** (`src/cmd.zig`)
   - Maps URL commands to UI handlers
   - Commands: summary, log, tree, commit, diff, refs, blame, stats, snapshot, etc.

5. **UI Handlers** (`src/ui/`)
   - Each command has a corresponding handler (e.g., `log.zig`, `commit.zig`)
   - Handlers generate HTML output directly to writer
   - Use shared utilities for common elements

### Key Design Patterns

1. **C Interop Pattern**
   - All libgit2 imports go through `git.c` to avoid type namespace conflicts
   - UI files use `const c = git.c;` or `const c = @cImport({...})` for additional headers
   - Extensive use of `@ptrCast` and `@constCast` for C pointer conversions

2. **Memory Management**
   - Repository paths constructed dynamically from `~/git/[repo_name].git`
   - Tag names must be duplicated to avoid use-after-free when C arrays are freed
   - Defer patterns used extensively for cleanup

3. **HTML Generation**
   - Direct HTML writing to output stream
   - HTML escaping through `html.htmlEscape()`
   - Static files served from `/gitweb.css`, `/gitweb.js`

## Common Issues and Solutions

### Zig 0.15.1 API Changes
- `ArrayList` is now unmanaged (use `.empty` instead of `.init()`)
- `allocPrintZ` → `allocPrintSentinel` with 0 sentinel at end
- `std.mem.split` → `std.mem.splitScalar` for single character delimiters
- Use `deprecatedWriter()` for stdout

### Comptime Errors
- If getting "unable to resolve comptime value" errors, create named struct types and use runtime initialization
- Example: `CommitStats` struct in `log.zig`

### Type Mismatches with libgit2
- Ensure all files import from the same `git.c` export
- Don't create multiple `@cImport` blocks for the same headers

## Repository Configuration

Repositories are expected to be bare git repositories located at:
- `~/git/[repository_name].git`

The CGI reads repository name from the `r` query parameter:
- `?r=factor` → looks for `~/git/factor.git`

## Testing

To test the CGI with a git repository:
1. Create a bare repository: `git init --bare ~/git/test.git`
2. Run: `QUERY_STRING="r=test" REQUEST_METHOD=GET ./zig-out/bin/gitweb.cgi`

## Static Files

Located in `static/`:
- `gitweb.css` - Stylesheet
- `gitweb.js` - JavaScript (if needed)
- `robots.txt` - Search engine directives

## Dependencies

- Zig 0.15.1 or later
- libgit2 (system library)
- zlib (system library)

On macOS with Homebrew:
```bash
brew install libgit2
```