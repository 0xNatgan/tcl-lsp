# Simple TCL standalone lsp server

# This is a simple implementation of a Language Server Protocol (LSP) server for TCL.
# It is designed to be run as a standalone server, and it can be used with any LSP client that supports the protocol.

Implementation is based on the [LSP specification](https://microsoft.github.io/language-server-protocol/).
Implemented features include:
- Initialization
- Shutdown
- Text Document Did Open
- Text Document Did Change
- Text Document Symbols
- Text Document References
- Text Document definition

Most of the implementation is based on hardcoded regex patterns to parse TCL code.

# Usage
To run the server, you need to have TCL installed on your system. You can then run the server using the following command:

```bash
chmod +x ./tcl-lsp.tcl
./tcl-lsp.tcl
```

# installation
You can clone the repository and run the server as described above. No additional installation is required.

for that, you can use the following command:

```bash
sudo apt install tcl  # install tcl (for Debian/Ubuntu)
sudo apt install tcllib  # install tcllib
git clone https://github.com/yourusername/tcl-lsp.git
cd tcl-lsp
chmod +x ./tcl-lsp.tcl
./tcl-lsp.tcl
```

You can see an example of request with the test_lsp.py file, which is a simple Python script that sends requests to the server and prints the responses. the script test the tcl server code directly.

you can run the test script with:

```bash
python3 test_lsp.py
```


# Requirements
- TCL 8.6 or higher
- Some TCL packages like `tcllib` for regex and other utilities

# Explanation of the project

This "project" is not a full-fledged LSP server, but rather a simple implementation that can be used as a starting point for building more complex LSP servers for TCL.
Mostly made with the help of ChatGpt and Claude. It was an implementation I needed for another project, so I decided to share it.

Thanks to https://github.com/jdc8/lsp which gave me a starting point to understand the architecture needed for this server.