1. Launch `sleep`
2. Using `/proc/self/maps`, find all required gadgets* in loaded libraries, if we can't find a gadget in automatically loaded libraries, find one anywhere in `/usr/lib`, and remember in which file it was found
3. Execute a longer running sleep, if necessary adding the new libraries from 2 via `LD_PRELOAD`
4. Re-find the gadgets, with the correct ASLR offset, and add them to our payload, along with any data
5. `dd` the payload directly over the stack, found in `/proc/${PID}/maps`, over `/proc/${PID}/mem`, pre-padded with NOPs
6. Wait for sleep to return from the `nanosleep` syscall, and our code is executed.

7. The payload I've written `open`s the file specified on the CLI, creates a `memfd`, uses `sendfile` to copy the binary to memory, and then uses `fexecve` to
   execute the in memory binary (which uses `execve(/proc/self/fd/X)` under the hood). Any payload ROP payload is possible, previously I had a payload which
   would `mmap` a `PROT_EXEC` section, copy a standard shellcode file into memory and execute that, which itself mounted a FUSE filesystem. This method was
   more flexible but also seemingly more brittle, and had large amounts of handwritten ASM.

* We only actually need a `NOP`, `POP {RDI, RSI, RDX, RCX, R8, R9}`, and a `JMP [SOMETHING]` (I've used `RAX` for parity with syscalls) for syscalls and PLT calls

## Features:
    - We can call any PLT (e.g glibc) function or syscall, with arbitrary arguments, including string arguments
    - Pure Bash ROPChain generator, including ELF parser to ensure grepped gadgets are within the `r-x` `.text` section

## Future work
    - Cache gadget offsets from the ASLR base on the first run, so the second run is faster
    - Interactivity with processes executed via the `fexecve` method. This can be achieved using FUSE's `passthrough` example, but this requires `libfuse` to be
      available.

## Why this works:

Parent processes can write to their children's `/proc/${PID}/mem` in most distros, due to the default value of /proc/sys/kernel/yama/ptrace_scope (`1`). The
less secure setting (`0`) allows for any process sharing a UID to write to another processes `/proc/${PID}/mem`.
To be the correct parent, we have to `exec dd` after we've generated the payload. This means that `dd` becomes the parent of `sleep`, but we then are unable to
execute something like `wait` to make the process interactive.

## Binary dependencies
- Bash
- dd
- GNU grep (this can be worked around but it's *slow*)

## Bash is the worst thing in the world
Bash does not handle binary data. ELF objects are binary data. This was 'fun'.
