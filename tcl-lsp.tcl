#!/usr/bin/env tclsh
# TCL Language Server Protocol Implementation
# A simple LSP server for TCL with basic capabilities

package require json
package require json::write

# Global state
array set documents {}
array set symbols {}
set request_id 0
set debug_mode 0

# Enable debug logging to stderr (set to 1 to enable)
proc debug_log {msg} {
    global debug_mode
    if {$debug_mode} {
        puts stderr "DEBUG: $msg"
        flush stderr
    }
}

# Read a complete LSP message from stdin
proc read_lsp_message {} {
    set headers {}
    
    # Read headers
    while {1} {
        if {[gets stdin line] == -1} {
            return ""
        }
        
        if {$line eq "\r" || $line eq ""} {
            break
        }
        
        lappend headers $line
    }
    
    # Parse Content-Length header
    set content_length 0
    foreach header $headers {
        if {[regexp {^Content-Length:\s*(\d+)} $header -> length]} {
            set content_length $length
            break
        }
    }
    
    if {$content_length == 0} {
        return ""
    }
    
    # Read the JSON content
    set content [read stdin $content_length]
    return $content
}

# Send an LSP message to stdout
proc send_lsp_message {content} {
    set content_length [string length $content]
    puts "Content-Length: $content_length\r"
    puts "\r"
    puts -nonewline $content
    flush stdout
}

# Convert Tcl dict to JSON recursively
proc dict_to_json {dict_data} {
    if {[catch {dict size $dict_data}]} {
        # Not a dict, return as string
        return [json::write string $dict_data]
    }
    
    set json_pairs {}
    dict for {key value} $dict_data {
        set json_key [json::write string $key]
        
        # Check if value is a dict
        if {[catch {dict size $value} size] == 0 && $size > 0} {
            set json_value [dict_to_json $value]
        } elseif {[llength $value] > 1 && [catch {dict size [lindex $value 0]} size] == 0} {
            # It's a list of dicts
            set json_list {}
            foreach item $value {
                if {[catch {dict size $item} item_size] == 0 && $item_size > 0} {
                    lappend json_list [dict_to_json $item]
                } else {
                    lappend json_list [json::write string $item]
                }
            }
            set json_value "\[[join $json_list ,]\]"
        } elseif {[string is integer $value]} {
            set json_value $value
        } else {
            set json_value [json::write string $value]
        }
        
        lappend json_pairs "$json_key:$json_value"
    }
    
    return "\{[join $json_pairs ,]\}"
}

# Send LSP response
proc send_response {id result} {
    # Handle different result types
    if {[llength $result] == 0} {
        # Empty result
        set json_result "null"
    } elseif {[llength $result] == 1 && [catch {dict size $result} size] == 0 && $size > 0} {
        # Single dict
        set json_result [dict_to_json $result]
    } elseif {[llength $result] > 1} {
        # List of items
        set json_items {}
        foreach item $result {
            if {[catch {dict size $item} item_size] == 0 && $item_size > 0} {
                lappend json_items [dict_to_json $item]
            } else {
                lappend json_items [json::write string $item]
            }
        }
        set json_result "\[[join $json_items ,]\]"
    } else {
        # Simple value
        if {[string is integer $result]} {
            set json_result $result
        } else {
            set json_result [json::write string $result]
        }
    }
    
    set response "\{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$json_result\}"
    send_lsp_message $response
    debug_log "Sent response: $response"
}

# Send LSP error response
proc send_error {id code message} {
    set json_message [json::write string $message]
    set response "\{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":\{\"code\":$code,\"message\":$json_message\}\}"
    send_lsp_message $response
    debug_log "Sent error: $response"
}

# Parse TCL content and extract symbols
proc parse_tcl_symbols {content} {
    debug_log "parse_tcl_symbols called"
    set symbols_list {}
    set lines [split $content "\n"]
    set line_num 0
    set inside_class 0
    set current_class ""
    set class_start_line 0

    foreach line $lines {
        set trimmed [string trim $line]

        # Skip empty lines and comments
        if {$trimmed eq "" || [string match "#*" $trimmed]} {
            incr line_num
            continue
        }

        # Detect TclOO class definition
        if {[regexp {^\s*oo::class\s+create\s+([a-zA-Z_][a-zA-Z0-9_]*)} $line -> class_name]} {
            set start_char [string first $class_name $line]
            if {$start_char == -1} {set start_char 0}
            set symbol [dict create \
                name $class_name \
                kind 5 \
                range [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $class_name]}]]] \
                selectionRange [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $class_name]}]]]]
            lappend symbols_list $symbol
            set inside_class 1
            set current_class $class_name
            set class_start_line $line_num
            incr line_num
            continue
        }

        # Detect method inside class body
        if {$inside_class && [regexp {^\s*method\s+([a-zA-Z_][a-zA-Z0-9_]*)\b} $line -> method_name]} {
            set start_char [string first $method_name $line]
            if {$start_char == -1} {set start_char 0}
            set symbol [dict create \
                name $method_name \
                kind 6 \
                range [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $method_name]}]]] \
                selectionRange [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $method_name]}]]]]
            lappend symbols_list $symbol
        }

        # End of class body (very naive: look for closing brace at start of line)
        if {$inside_class && [regexp {^\s*\}} $line]} {
            set inside_class 0
            set current_class ""
        }

        # Existing: proc
        if {[regexp {^\s*proc\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+(\{(?:[^{}]|\{[^{}]*\})*\})} $line -> proc_name args]} {
            set start_char [string first $proc_name $line]
            if {$start_char == -1} {set start_char 0}
            set symbol [dict create \
                name $proc_name \
                kind 12 \
                range [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $proc_name]}]]] \
                selectionRange [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $proc_name]}]]]]
            lappend symbols_list $symbol
        }

        # Existing: namespace
        if {[regexp {^\s*namespace\s+eval\s+([a-zA-Z_][a-zA-Z0-9_:]*)} $line -> ns_name]} {
            set start_char [string first $ns_name $line]
            if {$start_char == -1} {set start_char 0}
            set symbol [dict create \
                name $ns_name \
                kind 3 \
                range [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $ns_name]}]]] \
                selectionRange [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $ns_name]}]]]]
            lappend symbols_list $symbol
        }

        incr line_num
    }

    return $symbols_list
}

# Get word at specific position
proc get_word_at_position {content line_num char_pos} {
    set lines [split $content "\n"]
    
    if {$line_num >= [llength $lines]} {
        return ""
    }
    
    set line [lindex $lines $line_num]
    set line_length [string length $line]
    
    if {$char_pos >= $line_length} {
        return ""
    }
    
    # Find word boundaries
    set start $char_pos
    set end $char_pos
    
    # Move start backward
    while {$start > 0} {
        set char [string index $line [expr {$start - 1}]]
        if {![string is alnum $char] && $char ne "_"} {
            break
        }
        incr start -1
    }
    
    # Move end forward
    while {$end < $line_length} {
        set char [string index $line $end]
        if {![string is alnum $char] && $char ne "_"} {
            break
        }
        incr end
    }
    
    if {$start < $end} {
        return [string range $line $start [expr {$end - 1}]]
    }
    
    return ""
}

# Find all references to a symbol
proc find_references {content symbol_name} {
    set references {}
    set lines [split $content "\n"]
    set line_num 0
    
    foreach line $lines {
        set start_pos 0
        while {[set pos [string first $symbol_name $line $start_pos]] != -1} {
            # Check if it's a whole word
            set is_word_start [expr {$pos == 0 || (![string is alnum [string index $line [expr {$pos - 1}]]] && [string index $line [expr {$pos - 1}]] ne "_")}]
            set next_pos [expr {$pos + [string length $symbol_name]}]
            set is_word_end [expr {$next_pos >= [string length $line] || (![string is alnum [string index $line $next_pos]] && [string index $line $next_pos] ne "_")}]
            
            if {$is_word_start && $is_word_end} {
                set location [dict create \
                    range [dict create \
                        start [dict create line $line_num character $pos] \
                        end [dict create line $line_num character [expr {$pos + [string length $symbol_name]}]]]]
                
                lappend references $location
            }
            
            set start_pos [expr {$pos + 1}]
        }
        incr line_num
    }
    
    return $references
}

# Find definition of a symbol
proc find_definition {content symbol_name} {
    set lines [split $content "\n"]
    set line_num 0
    
    # Escape regex metacharacters in symbol_name
    set safe_symbol_name $symbol_name
    regsub -all {([\\\[\]\^\$\.\|\?\*\+\(\)])} $safe_symbol_name {\\\1} safe_symbol_name
    foreach line $lines {
        # Look for procedure definitions (allow for arguments and whitespace)
        set re [format {^\s*proc\s+%s(\s+|\s*\{)} $safe_symbol_name]
        if {[regexp $re $line]} {
            set start_char [string first $symbol_name $line]
            if {$start_char == -1} {set start_char 0}
            return [list [dict create \
                range [dict create \
                    start [dict create line $line_num character $start_char] \
                    end [dict create line $line_num character [expr {$start_char + [string length $symbol_name]}]]]]]
        }
        incr line_num
    }
    
    return {}
}

# Handle initialize request
proc handle_initialize {params id} {
    set result [dict create capabilities [dict create \
        textDocumentSync 1 \
        documentSymbolProvider true \
        referencesProvider true \
        definitionProvider true]]
    send_response $id $result
    debug_log "Initialized with capabilities"
}

# Handle shutdown request
proc handle_shutdown {params id} {
    send_response $id [dict create]
    debug_log "Shutdown requested"
}

# Handle textDocument/didOpen notification
proc handle_did_open {params} {
    global documents symbols
    
    set text_document [dict get $params textDocument]
    set uri [dict get $text_document uri]
    set text [dict get $text_document text]
    
    set documents($uri) $text
    set symbols($uri) [parse_tcl_symbols $text]
    
    debug_log "Document opened: $uri"
}

# Handle textDocument/didChange notification
proc handle_did_change {params} {
    global documents symbols
    
    set text_document [dict get $params textDocument]
    set uri [dict get $text_document uri]
    set content_changes [dict get $params contentChanges]
    
    # For simplicity, we assume full document updates
    foreach change $content_changes {
        if {[dict exists $change text]} {
            set documents($uri) [dict get $change text]
            set symbols($uri) [parse_tcl_symbols $documents($uri)]
            break
        }
    }
    
    debug_log "Document changed: $uri"
}

# Handle textDocument/documentSymbol request
proc handle_document_symbol {params id} {
    global documents symbols
    set text_document [dict get $params textDocument]
    set uri [dict get $text_document uri]
    if {[info exists documents($uri)]} {
        set result $symbols($uri)
        send_response $id $result
    } else {
        send_response $id [list]
    }
    debug_log "Document symbols requested for: $uri"
}

# Handle textDocument/references request
proc handle_references {params id} {
    global documents
    set text_document [dict get $params textDocument]
    set uri [dict get $text_document uri]
    set position [dict get $params position]
    if {![info exists documents($uri)]} {
        send_response $id [list]
        return
    }
    set line [dict get $position line]
    set character [dict get $position character]
    set content $documents($uri)
    set word [get_word_at_position $content $line $character]
    if {$word eq ""} {
        send_response $id [list]
        return
    }
    set references [find_references $content $word]
    # Add URI to each reference
    set result [list]
    foreach ref $references {
        dict set ref uri $uri
        lappend result $ref
    }
    send_response $id $result
    debug_log "References found for '$word': [llength $result]"
}

# Handle textDocument/definition request
proc handle_definition {params id} {
    global documents
    set text_document [dict get $params textDocument]
    set uri [dict get $text_document uri]
    set position [dict get $params position]
    if {![info exists documents($uri)]} {
        send_response $id [list]
        return
    }
    set line [dict get $position line]
    set character [dict get $position character]
    set content $documents($uri)
    set word [get_word_at_position $content $line $character]
    if {$word eq ""} {
        send_response $id [list]
        return
    }
    set definitions [find_definition $content $word]
    # Add URI to each definition
    set result [list]
    foreach def $definitions {
        dict set def uri $uri
        lappend result $def
    }
    send_response $id $result
    debug_log "Definition found for '$word': [llength $result]"
}

# Main message handler
proc handle_message {message} {
    if {[catch {set parsed [json::json2dict $message]} error]} {
        debug_log "JSON parse error: $error"
        return
    }
    
    debug_log "Received: $message"
    
    if {![dict exists $parsed method]} {
        debug_log "No method in message"
        return
    }
    
    set method [dict get $parsed method]
    if {[dict exists $parsed params]} {
        set params [dict get $parsed params]
    } else {
        set params {}
    }
    if {[dict exists $parsed id]} {
        set id [dict get $parsed id]
    } else {
        set id ""
    }
    
    switch $method {
        "initialize" {
            handle_initialize $params $id
        }
        "shutdown" {
            handle_shutdown $params $id
        }
        "exit" {
            debug_log "Exit requested"
            exit 0
        }
        "textDocument/didOpen" {
            handle_did_open $params
        }
        "textDocument/didChange" {
            handle_did_change $params
        }
        "textDocument/documentSymbol" {
            handle_document_symbol $params $id
        }
        "textDocument/references" {
            handle_references $params $id
        }
        "textDocument/definition" {
            handle_definition $params $id
        }
        default {
            if {$id ne ""} {
                send_error $id -32601 "Method not found: $method"
            }
            debug_log "Unknown method: $method"
        }
    }
}

# Main loop
proc main {} {
    debug_log "TCL LSP Server starting..."
    
    while {1} {
        set message [read_lsp_message]
        
        if {$message eq ""} {
            debug_log "Connection closed"
            break
        }
        
        handle_message $message
    }
    
    debug_log "TCL LSP Server exiting"
}

if {[info exists argv0] && $argv0 eq [info script] && $argc > 0} {
    set filename [lindex $argv 0]
    set f [open $filename r]
    set content [read $f]
    close $f
    puts "Symbols:"
    puts [parse_tcl_symbols $content]
    exit 0
}

# Start the server
if {[info exists argv0] && $argv0 eq [info script]} {
    main
}