# mini-nginx

A minimal nginx server written in Zig (or maybe c - not using zig std library for core socket stuff).

## TODO
- [ ] Need to obey connection header
- [ ] CPU Affinity
- [ ] Throw errors properly (purposefully was trying to not use error sets initially to understand how zig std works)
