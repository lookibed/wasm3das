options gen2
options indenting = 4

module abi_storage shared public

require modules/wasm3das/source/abi/gen/abi_eden_storage public
require strings
require math

/*
    abi_storage.das: the eden_storage model shared by every host, so all of
    them accept, refuse and answer exactly alike (ABI.md 3, 5).

    A namespace is a set of named blobs; each instance is bound to one
    namespace by its host (storage_bind). The model keeps the namespaces in
    memory for the life of the script context; persistence is the host's:
    the headless host has none (a namespace outlives its instances, which
    is what the tests need), the Eden host loads a namespace from the
    engine's local storage on first use and saves it after every change,
    rolling the change back when the save fails (ERR_IO).

    Engine-free.
*/


struct StorageSpace {
    loaded : bool = false                 // the host loaded it from its persistence
    blobs : table<string; array<uint8>>
}


var private g_spaces : table<string; StorageSpace>
var private g_bound : table<int; string>   // instance id -> namespace


def public storage_bind(id : int; ns : string) {
    g_bound[id] = ns
    if (!(g_spaces |> key_exists(ns))) {
        g_spaces[ns] <- StorageSpace()
    }
}


def public storage_unbind(id : int) {
    g_bound |> erase(id)
}


def public storage_namespace(id : int) : string {
    return (g_bound |> key_exists(id)) ? g_bound[id] : ""
}


def public storage_valid_name(name : string) : bool {
    return length(name) >= 1 && length(name) <= EDEN_STORAGE_MAX_NAME
}


def public storage_is_loaded(ns : string) : bool {
    var loaded = false
    g_spaces |> get(ns) $(space) {
        loaded = space.loaded
    }
    return loaded
}


// the host's persistence filled the namespace (replaces what is there)
def public storage_set_loaded(ns : string; var blobs : table<string; array<uint8>>) {
    g_spaces |> get(ns) $(var space) {
        space.blobs <- blobs
        space.loaded = true
    }
}


def public storage_total(ns : string) : int {
    var total = 0
    g_spaces |> get(ns) $(space) {
        for (b in values(space.blobs)) {
            total += length(b)
        }
    }
    return total
}


def public storage_has(ns : string; name : string) : bool {
    var found = false
    g_spaces |> get(ns) $(space) {
        found = space.blobs |> key_exists(name)
    }
    return found
}


def public storage_size(ns : string; name : string) : int {
    if (!storage_valid_name(name)) {
        return EDEN_STORAGE_ERR_NAME
    }
    var size = EDEN_STORAGE_ERR_NOT_FOUND
    g_spaces |> get(ns) $(space) {
        space.blobs |> get(name) $(b) {
            size = length(b)
        }
    }
    return size
}


def public storage_read(var rt : M3Runtime; ns : string; name : string; offset : int; dst : AbiBytes) : int {
    if (!storage_valid_name(name)) {
        return EDEN_STORAGE_ERR_NAME
    }
    var n = EDEN_STORAGE_ERR_NOT_FOUND
    g_spaces |> get(ns) $(space) {
        space.blobs |> get(name) $(b) {
            if (offset < 0 || offset > length(b)) {
                n = EDEN_STORAGE_ERR_RANGE
            } else {
                n = min(dst.len, length(b) - offset)
                for (i in range(n)) {
                    rt.mem[dst.ptr + i] = b[offset + i]
                }
            }
        }
    }
    return n
}


// the checks of eden_storage.write before anything changes
def public storage_check_write(ns : string; name : string; len : int) : int {
    if (!storage_valid_name(name)) {
        return EDEN_STORAGE_ERR_NAME
    }
    let old = max(storage_size(ns, name), 0)
    if (storage_total(ns) - old + len > EDEN_STORAGE_MAX_TOTAL_BYTES) {
        return EDEN_STORAGE_ERR_FULL
    }
    return EDEN_STORAGE_OK
}


// a copy of the blob (empty when absent), for rollbacks
def public storage_copy(ns : string; name : string) : array<uint8> {
    var out : array<uint8>
    g_spaces |> get(ns) $(space) {
        space.blobs |> get(name) $(b) {
            out := b
        }
    }
    return <- out
}


def public storage_put(ns : string; name : string; var bytes : array<uint8>) {
    g_spaces |> get(ns) $(var space) {
        space.blobs[name] <- bytes
    }
}


def public storage_put_from(rt : M3Runtime; ns : string; name : string; data : AbiBytes) {
    var bytes : array<uint8>
    resize(bytes, data.len)
    for (i in range(data.len)) {
        bytes[i] = rt.mem[data.ptr + i]
    }
    storage_put(ns, name, bytes)
}


def public storage_erase(ns : string; name : string) {
    g_spaces |> get(ns) $(var space) {
        space.blobs |> erase(name)
    }
}


// every blob of a namespace, for the host's persistence
def public storage_each(ns : string; blk : block<(name : string; bytes : array<uint8>) : void>) {
    g_spaces |> get(ns) $(space) {
        for (k, v in keys(space.blobs), values(space.blobs)) {
            invoke(blk, k, v)
        }
    }
}


// forgets a namespace entirely (tests)
def public storage_drop_namespace(ns : string) {
    g_spaces |> erase(ns)
}
