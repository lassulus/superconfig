# llm-agents' orca with a working darwin launcher. Upstream links
# bin/orca-ide straight to Orca.app/Contents/MacOS/Orca; Electron then looks
# for its helper apps relative to the symlink and dies with "Unable to find
# helper app". Executing the binary by its real path inside the bundle works.
{
  stdenvNoCC,
  runtimeShell,
  llm-agents,
}:
if stdenvNoCC.hostPlatform.isDarwin then
  llm-agents.orca.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm $out/bin/orca-ide
      cat >$out/bin/orca-ide <<EOF
      #!${runtimeShell}
      exec "$out/Applications/Orca.app/Contents/MacOS/Orca" "\$@"
      EOF
      chmod +x $out/bin/orca-ide
    '';
  })
else
  llm-agents.orca
