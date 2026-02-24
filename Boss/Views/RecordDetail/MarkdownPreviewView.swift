import SwiftUI
import WebKit

// MARK: - MarkdownPreviewView (Markdown 预览视图)
struct MarkdownPreviewView: View {
    let markdown: String
    
    var body: some View {
        WebView(content: generateHTML(from: markdown))
            .padding(20)
    }
    
    /// 将 Markdown 转换为 HTML
    private func generateHTML(from markdown: String) -> String {
        let css = """
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                line-height: 1.6;
                color: #333;
                max-width: 800px;
                margin: 0 auto;
                padding: 20px;
                background-color: #f5f5f5;
            }
            h1, h2, h3, h4, h5, h6 {
                color: #2c3e50;
                margin-top: 1.5em;
                margin-bottom: 0.8em;
            }
            p {
                margin-bottom: 1em;
            }
            a {
                color: #3498db;
                text-decoration: none;
            }
            a:hover {
                text-decoration: underline;
            }
            code {
                background-color: #f0f0f0;
                padding: 0.2em 0.4em;
                border-radius: 3px;
                font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
                font-size: 0.9em;
            }
            pre {
                background-color: #f0f0f0;
                padding: 1em;
                border-radius: 5px;
                overflow-x: auto;
                margin-bottom: 1em;
            }
            pre code {
                background-color: transparent;
                padding: 0;
            }
            ul, ol {
                margin-bottom: 1em;
                padding-left: 1.5em;
            }
            li {
                margin-bottom: 0.5em;
            }
            blockquote {
                border-left: 4px solid #3498db;
                padding-left: 1em;
                margin-left: 0;
                color: #666;
                font-style: italic;
            }
            img {
                max-width: 100%;
                height: auto;
                border-radius: 5px;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                margin-bottom: 1em;
            }
            th, td {
                border: 1px solid #ddd;
                padding: 8px;
                text-align: left;
            }
            th {
                background-color: #f2f2f2;
                font-weight: bold;
            }
        </style>
        """
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(css)
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        </head>
        <body>
            <div id="content"></div>
            <script>
                document.getElementById('content').innerHTML = marked.parse(`\(markdown)`);
            </script>
        </body>
        </html>
        """
        
        return html
    }
}

// MARK: - WebView (WKWebView 包装器)
struct WebView: NSViewRepresentable {
    let content: String
    
    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(content, baseURL: nil)
    }
}
