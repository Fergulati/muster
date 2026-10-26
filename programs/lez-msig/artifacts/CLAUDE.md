# programs/lez-msig/artifacts/

`msig.bin`: the DEPLOYED guest (R0BF). Its image id is the program's identity, and every private PDA
derives from it, so `methods/build.rs` embeds this file rather than rebuilding the guest. Replace it only
with a build you deploy.
