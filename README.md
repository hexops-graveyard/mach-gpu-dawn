<a href="https://machengine.org/pkg/mach-gpu-dawn">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="https://machengine.org/assets/mach/gpu-dawn-full-dark.svg">
        <img alt="mach-gpu-dawn" src="https://machengine.org/assets/mach/gpu-dawn-full-light.svg" height="150px">
    </picture>
</a>

Google’s Dawn WebGPU implementation, cross-compiled with Zig into a single static library

## Features

`mach/gpu-dawn` builds [Dawn](https://dawn.googlesource.com/dawn/), Google Chrome's WebGPU implementation, requiring nothing more than `zig` and `git` to build and cross-compile a static Dawn library for every OS:

* No cmake
* No ninja
* No `gn`
* No system dependencies (xcode, etc.)
* Automagic cross compilation out of the box with nothing more than `zig` and `git`!
* Builds a single static `libdawn.a`

Note: This does not build WebGPU `webgpu.h` symbols by default, see [the docs](https://machengine.org/pkg/mach-gpu-dawn) for more info.

## Documentation

[machengine.org/pkg/mach-gpu-dawn](https://machengine.org/pkg/mach-gpu-dawn)

## Join the community

Join the [Mach community on Discord](https://discord.gg/XNG3NZgCqp) to discuss this project, ask questions, get help, etc.

## Issues

Issues are tracked in the [main Mach repository](https://github.com/hexops/mach/issues?q=is%3Aissue+is%3Aopen+label%3Agpu-dawn).
