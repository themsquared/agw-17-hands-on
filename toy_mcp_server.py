import sys
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("toy-ops-server")

@mcp.tool()
def list_files(path: str = ".") -> str:
    """List files in a directory (read-only, safe)."""
    print(f"[toy-ops-server] list_files called with path={path}", file=sys.stderr)
    return f"README.md\nconfig.yaml\nmain.py  (in {path})"

@mcp.tool()
def delete_database(name: str) -> str:
    """Permanently delete a named database. Destructive."""
    print(f"[toy-ops-server] DELETE_DATABASE EXECUTED name={name}", file=sys.stderr)
    return f"DELETED database '{name}'"

if __name__ == "__main__":
    mcp.run(transport="stdio")
