# Database Schema Visualization

This directory contains GraphViz diagrams for the Kaimon database schema.

## Files

- **database-schema.dot** - Complete schema diagram showing tables, relationships, indices, and use cases

## Viewing the Diagram

### Online (No Installation Required)

1. Visit [Graphviz Online](http://www.webgraphviz.com/)
2. Copy the contents of `database-schema.dot`
3. Paste into the editor and click "Generate Graph"

Or use [Edotor](https://edotor.net/) for a better interactive experience.

### Command Line (requires Graphviz)

Install Graphviz:
```bash
# macOS
brew install graphviz

# Ubuntu/Debian
sudo apt-get install graphviz

# Windows (via Chocolatey)
choco install graphviz
```

Generate diagrams:
```bash
# PNG format (recommended for documentation)
dot -Tpng docs/database-schema.dot -o docs/database-schema.png

# SVG format (scalable, best for web)
dot -Tsvg docs/database-schema.dot -o docs/database-schema.svg

# PDF format (best for printing)
dot -Tpdf docs/database-schema.dot -o docs/database-schema.pdf

# Interactive HTML with zoom/pan
dot -Tsvg docs/database-schema.dot | dot -Tcmapx > docs/database-schema.html
```

### VS Code Extension

Install the [Graphviz Preview](https://marketplace.visualstudio.com/items?itemName=EFanZh.graphviz-preview) extension:
1. Open VS Code
2. Go to Extensions (⌘+Shift+X)
3. Search for "Graphviz Preview"
4. Install the extension
5. Open `database-schema.dot` and press ⌘+K V to preview

## Schema Overview

### Tables

- **sessions** (Blue) - Core session tracking with metadata
- **events** (Purple) - Lifecycle events and execution timing
- **interactions** (Green) - Complete message content (requests/responses)

### Relationships

- Solid lines: Foreign key relationships
- Dashed orange: Logical relationships (request/response pairs)
- Dotted gray: Index associations

### Key Features

- **Session Reconstruction**: Complete timeline of all interactions and events
- **Request/Response Pairing**: Automatic linking via `request_id`
- **Performance Indices**: Optimized for common query patterns
- **JSON Storage**: Full message content preserved for debugging
- **Analytics Ready**: Pre-computed metrics and summaries

## Example Queries

See the "Key Use Cases" section in the diagram for common operations:
- 📊 Session reconstruction with `reconstruct_session()`
- 📈 Analytics with `get_session_summary()`
- 🔍 Message inspection with filtering
- 🐛 Error debugging and audit trails
