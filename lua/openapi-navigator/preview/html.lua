--- openapi-navigator.nvim — HTML template for the browser preview.
--- Returns a self-contained HTML page that loads RapiDoc from CDN and
--- connects to the local SSE endpoint for live reload.

local M = {}

--- Return the HTML string for the preview page.
--- @param opts table  { theme: "dark"|"light" }
--- @return string
function M.render(opts)
	local theme = (opts and opts.theme) or "dark"
	local bg = theme == "dark" and "#1a1a1a" or "#ffffff"

	return string.format(
		[[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>OpenAPI Preview</title>
  <script type="module" src="https://unpkg.com/rapidoc/dist/rapidoc-min.js"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: %s; }
    rapi-doc { display: block; width: 100%%; height: 100vh; }
  </style>
</head>
<body>
  <rapi-doc
    id="api-doc"
    spec-url="/spec"
    render-style="read"
    theme="%s"
    show-header="false"
    allow-try="true"
    allow-spec-url-load="false"
    allow-spec-file-load="false"
  ></rapi-doc>
  <script>
    (function () {
      var evtSource = new EventSource('/events');

      evtSource.onmessage = function (e) {
        if (e.data === 'reload') {
          var doc = document.getElementById('api-doc');
          if (doc) {
            doc.setAttribute('spec-url', '/spec?t=' + Date.now());
          }
        } else if (e.data === 'shutdown') {
          evtSource.close();
        }
      };

      evtSource.onerror = function () {
        // Server stopped or connection lost — retry is handled automatically
        // by EventSource. If the server is gone, reconnect attempts will fail
        // silently until it comes back.
      };
    })();
  </script>
</body>
</html>
]],
		bg,
		theme
	)
end

return M
