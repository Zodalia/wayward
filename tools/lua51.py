"""Runs a Lua script with lupa's embedded Lua 5.1, the game's Lua version.

The suite runs on any Lua, but only Lua 5.1 refuses to pause a background job
inside a pcall ("attempt to yield across metamethod/C-call boundary"), as the
game does. Needs `pip install lupa` (2.x).

Usage (from the repository root): python3 -I tools/lua51.py tests/wayward_smoke.lua
"""

import sys

import lupa.lua51 as lua51


def main(argv):
    script, args = argv[1], argv[2:]
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("arg = {}")
    lua_arg = runtime.globals().arg
    lua_arg[0] = script
    for i, a in enumerate(args, 1):
        lua_arg[i] = a
    runtime.globals().dofile(script)


if __name__ == "__main__":
    main(sys.argv)
