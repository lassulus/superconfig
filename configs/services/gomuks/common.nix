# gomuks web (github:gomuks/gomuks), a Matrix client: the backend keeps
# the Matrix session and its crypto keys and serves the web app; the
# Android/desktop apps connect to it as well. It runs on `backend`
# (host.nix) behind nginx on `proxy` (proxy.nix), which reaches it over
# retiolum. Access is gomuks' own web password only. Imported by both.
{
  domain = "gomuks.lassul.us";
  backend = "styx";
  proxy = "neoprism";
  port = 29325;
}
