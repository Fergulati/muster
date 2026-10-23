# programs/lez-msig/methods/

`msig_methods` builds `guest/` with risc0-build and embeds `MSIG_ELF` (the R0BF `.bin` that
`infra/lez/localnet.sh deploy` takes) and `MSIG_ID` (its image id). The guest is its own cargo
project (`[workspace]` in its manifest), built with rzup's risc0 toolchain.
