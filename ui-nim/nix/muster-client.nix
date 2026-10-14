# muster_module's typed consumer client, generated at BUILD time from muster.lidl by the
# logos-nim-sdk generator (exo-607 T5): the same contract and generator the module's
# own surface comes from, which is the code sharing ADR-019 means. Never committed, so
# it cannot drift from the contract: a method the view calls that the contract lacks,
# or calls with the wrong arity, is a compile error in the app.
#
# Each contract method becomes `<m>` (sync, lenient), `<m>OrRaise` and `<m>Async(…,
# done)`. The app uses only the async twin: its backend shares the Qt main thread
# with the view, so a module call must never block it.
{ pkgs, logos-nim-sdk, lidl, contract, target ? "muster_module" }:

pkgs.runCommand "muster-client" { nativeBuildInputs = [ pkgs.nim ]; } ''
  export HOME=$TMPDIR
  nim c -d:release --hints:off --nimcache:$TMPDIR/nimcache \
    -d:LIDL_INC=${lidl}/include/lidl \
    -d:LIDL_C_A=${lidl}/lib/liblogos_lidl_c.a \
    -d:LIDL_A=${lidl}/lib/liblogos_lidl.a \
    -o:$TMPDIR/lidl_gen ${logos-nim-sdk}/lidl-gen/lidl_gen.nim
  mkdir -p $out
  $TMPDIR/lidl_gen client ${contract} $out/muster_client.nim ${target}
  grep -q 'proc healthAsync\*' $out/muster_client.nim || { echo "muster-client: no async twins (SDK too old?)" >&2; exit 1; }
''
