// zgit JavaScript functionality

(function() {
    'use strict';

    // Initialize on DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    function init() {
        initLineNumbers();
        initClipboard();
        initSearch();
        initTooltips();
        initSyntaxHighlighting();
        initGraphs();
        initKeyboardShortcuts();
    }

    // Add line numbers to code blocks
    function initLineNumbers() {
        const codeBlocks = document.querySelectorAll('pre.blob, pre.diff');
        codeBlocks.forEach(block => {
            if (block.classList.contains('no-linenumbers')) return;
            
            const lines = block.textContent.split('\n');
            const lineNumbers = document.createElement('span');
            lineNumbers.className = 'linenumbers';
            
            for (let i = 1; i <= lines.length; i++) {
                lineNumbers.innerHTML += i + '\n';
            }
            
            const wrapper = document.createElement('div');
            wrapper.style.display = 'flex';
            wrapper.appendChild(lineNumbers);
            wrapper.appendChild(block.cloneNode(true));
            
            block.parentNode.replaceChild(wrapper, block);
        });
    }

    // Copy to clipboard functionality
    function initClipboard() {
        // Add copy buttons to code blocks
        const codeBlocks = document.querySelectorAll('pre');
        codeBlocks.forEach(block => {
            const button = document.createElement('button');
            button.className = 'copy-btn';
            button.textContent = 'Copy';
            button.style.position = 'absolute';
            button.style.top = '8px';
            button.style.right = '8px';
            button.style.fontSize = '12px';
            button.style.padding = '4px 8px';
            button.style.background = '#f6f8fa';
            button.style.border = '1px solid #d1d5da';
            button.style.borderRadius = '4px';
            button.style.cursor = 'pointer';
            
            button.onclick = function() {
                const text = block.textContent;
                navigator.clipboard.writeText(text).then(() => {
                    button.textContent = 'Copied!';
                    setTimeout(() => {
                        button.textContent = 'Copy';
                    }, 2000);
                });
            };
            
            const wrapper = block.parentNode;
            wrapper.style.position = 'relative';
            wrapper.appendChild(button);
        });

        // Copy commit hash on click
        const commitHashes = document.querySelectorAll('.commit-hash');
        commitHashes.forEach(hash => {
            hash.style.cursor = 'pointer';
            hash.title = 'Click to copy';
            hash.onclick = function() {
                navigator.clipboard.writeText(hash.textContent);
                const originalText = hash.textContent;
                hash.textContent = 'Copied!';
                setTimeout(() => {
                    hash.textContent = originalText;
                }, 1000);
            };
        });
    }

    // Search functionality
    function initSearch() {
        const searchForm = document.getElementById('search-form');
        if (!searchForm) return;
        
        const searchInput = searchForm.querySelector('input[type="search"]');
        if (!searchInput) return;
        
        // Add search suggestions
        let searchTimeout;
        searchInput.addEventListener('input', function() {
            clearTimeout(searchTimeout);
            searchTimeout = setTimeout(() => {
                // Would implement search suggestions here
                console.log('Search:', searchInput.value);
            }, 300);
        });
        
        // Keyboard shortcut for search (/)
        document.addEventListener('keydown', function(e) {
            if (e.key === '/' && !isInputFocused()) {
                e.preventDefault();
                searchInput.focus();
            }
        });
    }

    // Tooltips
    function initTooltips() {
        // Add tooltips to relative dates
        const dates = document.querySelectorAll('.age, .date');
        dates.forEach(date => {
            const timestamp = date.getAttribute('data-timestamp');
            if (timestamp) {
                const fullDate = new Date(parseInt(timestamp) * 1000).toLocaleString();
                date.title = fullDate;
            }
        });

        // File size tooltips
        const sizes = document.querySelectorAll('.filesize');
        sizes.forEach(size => {
            const bytes = size.getAttribute('data-bytes');
            if (bytes) {
                size.title = parseInt(bytes).toLocaleString() + ' bytes';
            }
        });
    }

    // Basic syntax highlighting
    function initSyntaxHighlighting() {
        const codeBlocks = document.querySelectorAll('pre.blob');
        codeBlocks.forEach(block => {
            const filename = block.getAttribute('data-filename');
            if (!filename) return;
            
            const ext = filename.split('.').pop().toLowerCase();
            const language = getLanguageFromExt(ext);
            
            if (language) {
                highlightCode(block, language);
            }
        });
    }

    function getLanguageFromExt(ext) {
        const languages = {
            'js': 'javascript',
            'jsx': 'javascript',
            'ts': 'typescript',
            'tsx': 'typescript',
            'py': 'python',
            'rb': 'ruby',
            'go': 'go',
            'rs': 'rust',
            'c': 'c',
            'cpp': 'cpp',
            'cc': 'cpp',
            'h': 'c',
            'hpp': 'cpp',
            'cs': 'csharp',
            'java': 'java',
            'php': 'php',
            'swift': 'swift',
            'kt': 'kotlin',
            'zig': 'zig',
            'sh': 'bash',
            'bash': 'bash',
            'zsh': 'bash',
            'fish': 'bash',
            'ps1': 'powershell',
            'yaml': 'yaml',
            'yml': 'yaml',
            'json': 'json',
            'xml': 'xml',
            'html': 'html',
            'htm': 'html',
            'css': 'css',
            'scss': 'scss',
            'sass': 'sass',
            'less': 'less',
            'sql': 'sql',
            'md': 'markdown',
            'markdown': 'markdown',
            'r': 'r',
            'R': 'r',
            'lua': 'lua',
            'vim': 'vim',
            'dockerfile': 'dockerfile',
            'Dockerfile': 'dockerfile',
            'makefile': 'makefile',
            'Makefile': 'makefile',
            'cmake': 'cmake',
            'nginx': 'nginx',
            'conf': 'nginx',
            'ini': 'ini',
            'toml': 'toml'
        };
        
        return languages[ext] || null;
    }

    function highlightCode(element, language) {
        // This is a very basic highlighter
        // In production, you'd use a library like Prism.js or highlight.js
        const code = element.textContent;
        let highlighted = code;
        
        // Basic keyword highlighting
        const keywords = getKeywords(language);
        if (keywords) {
            const keywordRegex = new RegExp('\\b(' + keywords.join('|') + ')\\b', 'g');
            highlighted = highlighted.replace(keywordRegex, '<span class="hl-keyword">$1</span>');
        }
        
        // String highlighting
        highlighted = highlighted.replace(/"([^"\\]|\\.)*"/g, '<span class="hl-string">"$1"</span>');
        highlighted = highlighted.replace(/'([^'\\]|\\.)*'/g, '<span class="hl-string">\'$1\'</span>');
        
        // Comment highlighting
        highlighted = highlighted.replace(/\/\/.*$/gm, '<span class="hl-comment">$&</span>');
        highlighted = highlighted.replace(/\/\*[\s\S]*?\*\//g, '<span class="hl-comment">$&</span>');
        
        // Number highlighting
        highlighted = highlighted.replace(/\b\d+\.?\d*\b/g, '<span class="hl-number">$&</span>');
        
        element.innerHTML = highlighted;
    }

    function getKeywords(language) {
        const keywordSets = {
            'javascript': ['const', 'let', 'var', 'function', 'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'break', 'continue', 'return', 'try', 'catch', 'finally', 'throw', 'new', 'class', 'extends', 'import', 'export', 'default', 'async', 'await'],
            'python': ['def', 'class', 'if', 'elif', 'else', 'for', 'while', 'break', 'continue', 'return', 'try', 'except', 'finally', 'raise', 'import', 'from', 'as', 'with', 'lambda', 'yield', 'global', 'nonlocal', 'assert', 'async', 'await'],
            'go': ['package', 'import', 'func', 'var', 'const', 'type', 'struct', 'interface', 'if', 'else', 'for', 'range', 'switch', 'case', 'default', 'break', 'continue', 'return', 'go', 'defer', 'select', 'chan'],
            'rust': ['fn', 'let', 'mut', 'const', 'struct', 'enum', 'trait', 'impl', 'if', 'else', 'match', 'for', 'while', 'loop', 'break', 'continue', 'return', 'use', 'mod', 'pub', 'crate', 'self', 'super', 'async', 'await', 'move'],
            'c': ['int', 'char', 'float', 'double', 'void', 'long', 'short', 'unsigned', 'signed', 'struct', 'union', 'enum', 'typedef', 'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break', 'continue', 'return', 'goto', 'static', 'extern', 'const', 'volatile', 'register', 'auto'],
            'zig': ['const', 'var', 'fn', 'pub', 'struct', 'enum', 'union', 'if', 'else', 'while', 'for', 'switch', 'break', 'continue', 'return', 'defer', 'errdefer', 'try', 'catch', 'async', 'await', 'suspend', 'resume', 'comptime', 'inline', 'export', 'extern', 'test']
        };
        
        return keywordSets[language] || null;
    }

    // Initialize commit graphs
    function initGraphs() {
        const graphContainers = document.querySelectorAll('.stats-graph');
        graphContainers.forEach(container => {
            const canvas = container.querySelector('canvas');
            if (!canvas) return;
            
            const ctx = canvas.getContext('2d');
            // Would implement actual graph drawing here
            drawSampleGraph(ctx, canvas.width, canvas.height);
        });
    }

    function drawSampleGraph(ctx, width, height) {
        // Draw a simple sample graph
        ctx.strokeStyle = '#0969da';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(0, height);
        
        for (let i = 0; i < width; i += 10) {
            const y = height - (Math.random() * height * 0.8);
            ctx.lineTo(i, y);
        }
        
        ctx.stroke();
    }

    // Keyboard shortcuts
    function initKeyboardShortcuts() {
        const shortcuts = {
            'g h': () => navigateTo('/'), // Go home
            'g r': () => navigateTo('?cmd=repolist'), // Go to repo list
            'g s': () => navigateTo('?cmd=summary'), // Go to summary
            'g l': () => navigateTo('?cmd=log'), // Go to log
            'g t': () => navigateTo('?cmd=tree'), // Go to tree
            'g b': () => navigateTo('?cmd=refs'), // Go to branches
            '?': showHelp, // Show help
        };
        
        let keyBuffer = '';
        let keyTimeout;
        
        document.addEventListener('keydown', function(e) {
            if (isInputFocused()) return;
            
            clearTimeout(keyTimeout);
            keyBuffer += e.key;
            
            keyTimeout = setTimeout(() => {
                keyBuffer = '';
            }, 1000);
            
            for (const [shortcut, action] of Object.entries(shortcuts)) {
                if (keyBuffer.endsWith(shortcut)) {
                    e.preventDefault();
                    action();
                    keyBuffer = '';
                    break;
                }
            }
        });
    }

    function isInputFocused() {
        const activeElement = document.activeElement;
        return activeElement && (
            activeElement.tagName === 'INPUT' ||
            activeElement.tagName === 'TEXTAREA' ||
            activeElement.tagName === 'SELECT' ||
            activeElement.contentEditable === 'true'
        );
    }

    function navigateTo(path) {
        window.location.href = path;
    }

    function showHelp() {
        const helpText = `
Keyboard Shortcuts:
g h - Go to home
g r - Go to repository list
g s - Go to summary
g l - Go to commit log
g t - Go to tree view
g b - Go to branches
/ - Focus search
? - Show this help
        `;
        alert(helpText);
    }

    // Export for use in other scripts
    window.zgit = {
        init: init,
        highlightCode: highlightCode,
        initGraphs: initGraphs
    };

})();