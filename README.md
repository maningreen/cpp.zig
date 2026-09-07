# C++ Translator
> [WARNING!]
> This project works for the test case; however, It's yet to work on the c++stdlib, and I'm currently not working on it.
## Basis

Goal: <br>
    Given any c++ Header, generate a zig file which can link with it.

Todo:
  - [x] virtual functions
  - [x] constructors
    - [x] private
    - [x] public
  - [x] destructors
    - [x] private
    - [x] public
  - [x] member functions
    - [x] private
    - [x] public
  - [x] inheritance
    - [x] private
    - [x] public
  - [x] member variables
    - [x] private
    - [x] public

  - [ ] static members
  - [ ] parent casting
  - [ ] virtual inheritance

## Usage

```bash
$ translator ./header.hpp
```

## Building

This project uses the zig build system, and depends on `castxml` as a runtime dependency.
Ensure `castxml` is in your `PATH` for the application to work.

```bash
$ zig build
```
