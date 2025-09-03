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
   - Additional handlers: `tree.zig`, `diff.zig`, `refs.zig`, `blame.zig`, `stats.zig`, `snapshot.zig`, `search.zig`, `tag.zig`, `blob.zig`, `plain.zig`, `patch.zig`, `atom.zig`, `clone.zig`, `repolist.zig`

6. **HTML Generation** (`src/html.zig`)
   - Provides `writeHeader()` and `writeFooter()` for consistent page structure
   - Handles navigation tabs, branch selector, and page metadata
   - Includes viewport meta tag for mobile responsiveness

7. **Configuration** (`src/config.zig`, `src/configfile.zig`)
   - Configuration system for CGI settings
   - Repository configuration parsing
   - Customizable paths, URLs, and display options

8. **Parsing Utilities** (`src/parsing.zig`)
   - Query string parsing
   - URL encoding/decoding
   - Timestamp formatting

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
- `gitweb.css` - Stylesheet (1583 lines)
- `gitweb.js` - JavaScript for UI interactions
- `chart.js` - Chart library for stats visualization
- `robots.txt` - Search engine directives
- `favicon*.png` - Favicon in multiple sizes
- `gitweb.png` - Logo image

## Dependencies

- Zig 0.15.1 or later
- libgit2 (system library)
- zlib (system library)

On macOS with Homebrew:
```bash
brew install libgit2
```

## Refactoring Opportunities

### Code Duplication Issues
The codebase has significant duplication across UI handlers (~400-500 duplicated lines):

1. **Repository opening pattern** - Repeated in 10+ files
2. **Commit/reference resolution** - Complex logic duplicated 6+ times  
3. **Branch/tag collection** - 50+ lines repeated in multiple handlers
4. **URL generation with parameters** - Duplicated URL building logic
5. **Path navigation in git trees** - Tree traversal code repeated

### CSS Optimization
The CSS file (1583 lines) has opportunities for cleanup:

1. **Unused classes** - ~57 classes defined but never used (mostly syntax highlighting)
2. **Missing definitions** - ~30 classes used in code but not styled
3. **Color repetition** - Color `#f6f8fa` used 24+ times (could use CSS variables)
4. **Unused dark mode** - Complete dark mode styles with no toggle mechanism

### Recommended Refactorings

1. **Extract common UI functions to `shared.zig`:**
   - `openRepositoryOrError()` - Handle repo opening with error display
   - `resolveCommitFromQuery()` - Parse and resolve commit references
   - `collectRefsMap()` - Build branch/tag reference mappings
   - `writeUrlBase()` - Generate consistent URL structures
   - `navigateToPath()` - Tree navigation helper

2. **CSS consolidation:**
   - Remove unused syntax highlighting classes
   - Add missing class definitions for error handling
   - Introduce CSS custom properties for repeated values
   - Consider removing dark mode if not planned