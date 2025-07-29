import subprocess
import json
import time

def make_lsp_message(payload):
    content = json.dumps(payload)
    return f"Content-Length: {len(content)}\r\n\r\n{content}".encode("utf-8")

def read_lsp_response(proc):
    headers = b""
    while True:
        line = b""
        while not line.endswith(b"\n"):
            c = proc.stdout.read(1)
            if not c:
                return None
            line += c
        if line in (b"\r\n", b"\n"):
            break
        headers += line
    for header in headers.decode().splitlines():
        if header.lower().startswith("content-length:"):
            length = int(header.split(":")[1].strip())
            break
    else:
        return None
    content = proc.stdout.read(length)
    return content.decode()

def main():
    # ================= FILE PATH BELOW =================
    file_path = "tcl-lsp.tcl"
    # ===================================================
    with open(file_path, "r") as f:
        tcl_code = f.read()

    proc = subprocess.Popen(
        ["tclsh", "tcl-lsp.tcl"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {}
        },
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": f"file:///{file_path}",
                    "languageId": "tcl",
                    "version": 1,
                    "text": tcl_code
                }
            }
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "textDocument/documentSymbol",
            "params": {
                "textDocument": {
                    "uri": f"file:///{file_path}"
                }
            }
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "shutdown",
            "params": {}
        },
        {
            "jsonrpc": "2.0",
            "method": "exit"
        }
    ]

    symbol_position = None

    for i, msg in enumerate(messages):
        proc.stdin.write(make_lsp_message(msg))
        proc.stdin.flush()
        time.sleep(0.2)
        if "id" in msg:
            resp = read_lsp_response(proc)
            label = f"Response to {msg.get('method', 'unknown')} (id={msg['id']}):"
            if resp:
                try:
                    resp_json = json.loads(resp)
                    print(label)
                    print(json.dumps(resp_json, indent=2))
                    if msg["method"] == "textDocument/documentSymbol":
                        symbols = resp_json.get("result", [])
                        if symbols:
                            first = symbols[0]
                            pos = first.get("range", {}).get("start", {})
                            symbol_position = {
                                "line": pos.get("line", 0),
                                "character": pos.get("character", 0)
                            }
                            def_msg = {
                                "jsonrpc": "2.0",
                                "id": 3,
                                "method": "textDocument/definition",
                                "params": {
                                    "textDocument": {
                                        "uri": f"file:///{file_path}"
                                    },
                                    "position": symbol_position
                                }
                            }
                            proc.stdin.write(make_lsp_message(def_msg))
                            proc.stdin.flush()
                            time.sleep(0.2)
                            def_resp = read_lsp_response(proc)
                            print(f"Response to textDocument/definition (id=3):")
                            if def_resp:
                                print(json.dumps(json.loads(def_resp), indent=2))
                            else:
                                print("<no response>")
                except Exception as e:
                    print(f"=============== ERROR ===============")
                    print(label)
                    print(resp)
                    print(f"Error parsing response: {e}")
                    print(f"=============== ERROR ===============")
            else:
                print(f"{label} <no response>")
                err = proc.stderr.read(4096)
                if err:
                    print("Server error output:", err.decode())

    proc.terminate()

if __name__ == "__main__":
    main()