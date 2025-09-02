const std = @import("std");

// Time constants
pub const TM_MIN: u32 = 60;
pub const TM_HOUR: u32 = TM_MIN * 60;
pub const TM_DAY: u32 = TM_HOUR * 24;
pub const TM_WEEK: u32 = TM_DAY * 7;
pub const TM_YEAR: u32 = TM_DAY * 365;
pub const TM_MONTH: f32 = @as(f32, @floatFromInt(TM_YEAR)) / 12.0;

// Default encoding
pub const PAGE_ENCODING = "UTF-8";

pub const DiffType = enum {
    unified,
    ssdiff,
    statonly,
};

pub const FilterType = enum {
    about,
    commit,
    source,
    email,
    auth,
    owner,
};

pub const Filter = struct {
    open: *const fn (self: *Filter) anyerror!void,
    close: *const fn (self: *Filter) anyerror!void,
    cleanup: *const fn (self: *Filter) void,
    argument_count: u32,
};

pub const Repo = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    name: []const u8,
    path: []const u8,
    desc: []const u8,
    extra_head_content: ?[]const u8,
    owner: ?[]const u8,
    homepage: ?[]const u8,
    defbranch: []const u8,
    module_link: ?[]const u8,
    readme: std.ArrayList([]const u8),
    section: ?[]const u8,
    clone_url: ?[]const u8,
    logo: ?[]const u8,
    logo_link: ?[]const u8,
    snapshot_prefix: ?[]const u8,
    snapshots: u32,
    enable_blame: bool,
    enable_commit_graph: bool,
    enable_log_filecount: bool,
    enable_log_linecount: bool,
    enable_remote_branches: bool,
    enable_subject_links: bool,
    enable_html_serving: bool,
    branch_sort: BranchSort,
    commit_sort: CommitSort,
    max_stats: ?Period,
    hide: bool,
    ignore: bool,
    owner_filter: ?*Filter,
    extra_head_content_filter: ?*Filter,
    commit_filter: ?*Filter,
    source_filter: ?*Filter,
    email_filter: ?*Filter,
    submodules: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) !*Repo {
        const repo = try allocator.create(Repo);
        repo.allocator = allocator;
        repo.url = "";
        repo.name = "";
        repo.path = "";
        repo.desc = "";
        repo.extra_head_content = null;
        repo.owner = null;
        repo.homepage = null;
        repo.defbranch = "master";
        repo.module_link = null;
        repo.readme = std.ArrayList([]const u8){
            .items = &.{},
            .capacity = 0,
        };
        repo.section = null;
        repo.clone_url = null;
        repo.logo = null;
        repo.logo_link = null;
        repo.snapshot_prefix = null;
        repo.snapshots = 0;
        repo.enable_blame = false;
        repo.enable_commit_graph = false;
        repo.enable_log_filecount = false;
        repo.enable_log_linecount = false;
        repo.enable_remote_branches = false;
        repo.enable_subject_links = false;
        repo.enable_html_serving = false;
        repo.branch_sort = .name;
        repo.commit_sort = .date;
        repo.max_stats = null;
        repo.hide = false;
        repo.ignore = false;
        repo.owner_filter = null;
        repo.extra_head_content_filter = null;
        repo.commit_filter = null;
        repo.source_filter = null;
        repo.email_filter = null;
        repo.submodules = std.StringHashMap([]const u8).init(allocator);
        return repo;
    }

    pub fn deinit(self: *Repo) void {
        // Free allocated strings
        if (self.name.len > 0) self.allocator.free(self.name);
        if (self.path.len > 0) self.allocator.free(self.path);
        if (self.url.len > 0) self.allocator.free(self.url);
        if (self.desc.len > 0) self.allocator.free(self.desc);

        self.readme.deinit(self.allocator);
        self.submodules.deinit();
        self.allocator.destroy(self);
    }
};

pub const BranchSort = enum {
    name,
    age,
};

pub const CommitSort = enum {
    date,
    topo,
};

pub const Period = enum {
    week,
    month,
    quarter,
    year,
};

pub const Config = struct {
    agefile: ?[]const u8,
    cache_root: []const u8,
    cache_enabled: bool,
    cache_size: usize,
    cache_dynamic_ttl: i32,
    cache_max_create_time: i32,
    cache_repo_ttl: i32,
    cache_root_ttl: i32,
    cache_scanrc_ttl: i32,
    cache_static_ttl: i32,
    cache_about_ttl: i32,
    cache_snapshot_ttl: i32,
    case_sensitive_sort: bool,
    clone_prefix: ?[]const u8,
    clone_url: ?[]const u8,
    commit_sort: CommitSort,
    css: []const u8,
    embedded: bool,
    enable_index_links: bool,
    enable_index_owner: bool,
    enable_blame: bool,
    enable_commit_graph: bool,
    enable_filter_overrides: bool,
    enable_follow_links: bool,
    enable_http_clone: bool,
    enable_log_filecount: bool,
    enable_log_linecount: bool,
    enable_remote_branches: bool,
    enable_subject_links: bool,
    enable_html_serving: bool,
    enable_tree_linenumbers: bool,
    favicon: []const u8,
    footer: ?[]const u8,
    head_include: ?[]const u8,
    header: ?[]const u8,
    logo: []const u8,
    logo_link: []const u8,
    max_atom_items: u32,
    max_commit_count: u32,
    max_lock_attempts: u32,
    max_msg_len: u32,
    max_repodesc_len: u32,
    max_blob_size: u32,
    max_repo_count: u32,
    max_stats: Period,
    mimetype_file: ?[]const u8,
    module_link: ?[]const u8,
    nocache: bool,
    noplainemail: bool,
    noheader: bool,
    project_list: ?[]const u8,
    readme: ?[]const u8,
    robots: []const u8,
    root_title: []const u8,
    root_desc: []const u8,
    root_readme: ?[]const u8,
    scanpath: ?[]const u8,
    scanpath_recurse: u32,
    section: ?[]const u8,
    repository_sort: ?[]const u8,
    section_sort: bool,
    snapshots: u32,
    summary_branches: u32,
    summary_log: u32,
    summary_tags: u32,
    strict_export: ?[]const u8,
    virtual_root: []const u8,
    mimetypes: std.StringHashMap([]const u8),
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    repo: ?*Repo,
    page: Page,
    cmd: []const u8,
    query: Query,
    env: Environment,

    pub fn init(allocator: std.mem.Allocator) !Context {
        return Context{
            .allocator = allocator,
            .cfg = try initDefaultConfig(allocator),
            .repo = null,
            .page = Page{},
            .cmd = "",
            .query = Query.init(allocator),
            .env = Environment{},
        };
    }

    pub fn deinit(self: *Context) void {
        self.query.deinit();
        if (self.repo) |repo| {
            repo.deinit();
        }
        // Free config allocated strings
        if (self.cfg.scanpath) |scanpath| {
            self.allocator.free(scanpath);
        }
        if (self.cfg.project_list) |project_list| {
            self.allocator.free(project_list);
        }
        // Free mimetypes map
        self.cfg.mimetypes.deinit();
    }

    pub fn parseRequest(self: *Context, query_string: []const u8, path_info: []const u8, method: []const u8) !void {
        _ = method; // TODO: Handle POST requests

        // Parse query string
        try self.parseQueryString(query_string);

        // Parse path info to determine repo and command
        try self.parsePath(path_info);

        // Get command from query string if present
        if (self.query.get("cmd")) |cmd| {
            self.cmd = cmd;
        }

        // Load repository if specified
        if (self.query.get("r")) |repo_name| {
            // std.debug.print("parseRequest: Loading repository '{s}'\n", .{repo_name});
            try self.loadRepository(repo_name);
            // std.debug.print("parseRequest: After loadRepository, ctx.repo = {?}\n", .{self.repo});
        } else {
            // std.debug.print("parseRequest: No 'r' parameter in query string\n", .{});
        }
    }

    fn loadRepository(self: *Context, repo_name: []const u8) !void {
        // std.debug.print("loadRepository: looking for repo '{s}'\n", .{repo_name});

        // First, try to find the repository in our configuration
        // TODO: Check if repository is already configured in a repo list

        // Create a new repo instance
        self.repo = try Repo.init(self.allocator);

        // Set basic repo properties
        self.repo.?.name = try self.allocator.dupe(u8, repo_name);
        self.repo.?.url = try self.allocator.dupe(u8, repo_name);

        // Determine repository path
        var repo_path: []const u8 = undefined;

        if (self.cfg.scanpath) |scan_path| {
            // std.debug.print("Using scan-path: {s}\n", .{scan_path});
            // Look for repository under scan-path
            // Try both with and without .git extension
            const path_with_git = try std.fmt.allocPrint(self.allocator, "{s}/{s}.git", .{ scan_path, repo_name });
            defer self.allocator.free(path_with_git);

            const path_without_git = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ scan_path, repo_name });
            defer self.allocator.free(path_without_git);

            // std.debug.print("Checking path: {s}\n", .{path_with_git});
            // std.debug.print("Checking path: {s}\n", .{path_without_git});

            // Check which path exists
            if (std.fs.accessAbsolute(path_with_git, .{})) |_| {
                // std.debug.print("Found repository at: {s}\n", .{path_with_git});
                repo_path = try self.allocator.dupe(u8, path_with_git);
            } else |_| {
                if (std.fs.accessAbsolute(path_without_git, .{})) |_| {
                    // std.debug.print("Found repository at: {s}\n", .{path_without_git});
                    repo_path = try self.allocator.dupe(u8, path_without_git);
                } else |_| {
                    // std.debug.print("Repository not found under scan-path\n", .{});
                    // Repository not found under scan-path
                    return error.RepositoryNotFound;
                }
            }
        } else {
            // std.debug.print("No scan-path configured, using default\n", .{});
            // No scan-path configured, fall back to default
            // This maintains backward compatibility
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch "/home";
            defer self.allocator.free(home);

            repo_path = try std.fmt.allocPrint(self.allocator, "{s}/git/{s}.git", .{ home, repo_name });
            // std.debug.print("Using default path: {s}\n", .{repo_path});
        }

        self.repo.?.path = repo_path;
        // std.debug.print("Repository path set to: {s}\n", .{repo_path});

        // Set some defaults
        self.repo.?.desc = try self.allocator.dupe(u8, "");
    }

    fn parseQueryString(self: *Context, query_string: []const u8) !void {
        // std.debug.print("parseQueryString: input = '{s}'\n", .{query_string});
        var iter = std.mem.tokenizeAny(u8, query_string, "&");
        while (iter.next()) |param| {
            const eq_pos = std.mem.indexOf(u8, param, "=");
            if (eq_pos) |pos| {
                const key = param[0..pos];
                const value = param[pos + 1 ..];
                // std.debug.print("parseQueryString: setting key='{s}', value='{s}'\n", .{key, value});
                try self.query.set(key, value);
            }
        }

        // Debug: Check what's in the query
        // if (self.query.get("r")) |r_value| {
        //     std.debug.print("parseQueryString: query has 'r' = '{s}'\n", .{r_value});
        // } else {
        //     std.debug.print("parseQueryString: query does not have 'r' parameter\n", .{});
        // }
    }

    fn parsePath(self: *Context, path_info: []const u8) !void {
        // Parse path_info to extract repo and command
        // Format: /<repo>/<cmd>/...
        if (path_info.len == 0 or path_info[0] != '/') {
            return;
        }

        var iter = std.mem.tokenizeAny(u8, path_info[1..], "/");
        if (iter.next()) |repo_name| {
            // TODO: Load repo by name
            _ = repo_name;
        }

        if (iter.next()) |cmd| {
            self.cmd = cmd;
        }
    }
};

fn initDefaultConfig(allocator: std.mem.Allocator) !Config {
    return Config{
        .agefile = null,
        .cache_root = "/var/cache/cgit",
        .cache_enabled = false,
        .cache_size = 0,
        .cache_dynamic_ttl = 5,
        .cache_max_create_time = 5,
        .cache_repo_ttl = 5,
        .cache_root_ttl = 5,
        .cache_scanrc_ttl = 15,
        .cache_static_ttl = -1,
        .cache_about_ttl = 15,
        .cache_snapshot_ttl = 5,
        .case_sensitive_sort = true,
        .clone_prefix = null,
        .clone_url = null,
        .commit_sort = .date,
        .css = "/gitweb.css",
        .embedded = false,
        .enable_index_links = false,
        .enable_index_owner = true,
        .enable_blame = false,
        .enable_commit_graph = false,
        .enable_filter_overrides = false,
        .enable_follow_links = false,
        .enable_http_clone = true,
        .enable_log_filecount = false,
        .enable_log_linecount = false,
        .enable_remote_branches = false,
        .enable_subject_links = false,
        .enable_html_serving = false,
        .enable_tree_linenumbers = true,
        .favicon = "/favicon.ico",
        .footer = null,
        .head_include = null,
        .header = null,
        .logo = "/gitweb.png",
        .logo_link = "https://github.com/mrjbq7/zig-gitweb",
        .max_atom_items = 10,
        .max_commit_count = 50,
        .max_lock_attempts = 5,
        .max_msg_len = 80,
        .max_repodesc_len = 80,
        .max_blob_size = 0,
        .max_repo_count = 50,
        .max_stats = .year,
        .mimetype_file = null,
        .module_link = null,
        .nocache = false,
        .noplainemail = false,
        .noheader = false,
        .project_list = null,
        .readme = null,
        .robots = "index, nofollow",
        .root_title = "Git repository browser",
        .root_desc = "a fast hypertext interface for the git revision control system",
        .root_readme = null,
        .scanpath = null,
        .scanpath_recurse = 1,
        .section = null,
        .repository_sort = null,
        .section_sort = true,
        .snapshots = 0,
        .summary_branches = 10,
        .summary_log = 10,
        .summary_tags = 10,
        .strict_export = null,
        .virtual_root = "/",
        .mimetypes = std.StringHashMap([]const u8).init(allocator),
    };
}

pub const Page = struct {
    mimetype: []const u8 = "text/html",
    charset: []const u8 = PAGE_ENCODING,
    filename: ?[]const u8 = null,
    size: usize = 0,
    modified: i64 = 0,
    expires: i64 = 0,
    etag: ?[]const u8 = null,
    title: []const u8 = "",
    status: u16 = 200,
    statusmsg: []const u8 = "OK",
    show_search: bool = false,
};

pub const Query = struct {
    params: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Query {
        return Query{
            .params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Query) void {
        self.params.deinit();
    }

    pub fn set(self: *Query, key: []const u8, value: []const u8) !void {
        try self.params.put(key, value);
    }

    pub fn get(self: *Query, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
};

pub const Environment = struct {
    cgit_config: ?[]const u8 = null,
    http_host: ?[]const u8 = null,
    https: ?[]const u8 = null,
    no_http: ?[]const u8 = null,
    path_info: ?[]const u8 = null,
    query_string: ?[]const u8 = null,
    request_method: ?[]const u8 = null,
    script_name: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    server_port: ?[]const u8 = null,
    http_cookie: ?[]const u8 = null,
    http_referer: ?[]const u8 = null,
    content_length: ?[]const u8 = null,
    http_user_agent: ?[]const u8 = null,
    authenticated: bool = false,
};
