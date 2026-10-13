{
  lib,
  fetchPypi,
  python313Packages,
}:
let
  py = python313Packages;

  # 0.18.1 added a runtime dependency on `websockets` (realtime transport) that
  # nixpkgs' derivation does not declare yet, so its wheel fails the
  # runtime-deps check. Add it until nixpkgs catches up.
  openai-agents = py.openai-agents.overridePythonAttrs (o: {
    dependencies = o.dependencies ++ [ py.websockets ];
  });

  # omnigent-client declares `omnigent` as a dependency, and omnigent declares
  # omnigent-client: the two are released in lockstep from the same repo. Break
  # the cycle by dropping the back-reference here; the final application below
  # provides `omnigent` itself.
  omnigent-client = py.buildPythonPackage rec {
    pname = "omnigent_client";
    version = "0.17.0";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-840EK8+ZfBOPP0lp5h974rkKtIs4eLC8uLaK23y8FhY=";
    };

    pythonRemoveDeps = [ "omnigent" ];

    dependencies = [
      py.httpx
      py.pydantic
    ];

    # No pythonImportsCheck: every module imports `omnigent`, which only exists
    # in the application closure below.
    doCheck = false;

    meta = {
      description = "Python client library for the Omnigent server API";
      homepage = "https://omnigent.ai";
      license = lib.licenses.asl20;
    };
  };

  omnigent-ui-sdk = py.buildPythonPackage rec {
    pname = "omnigent_ui_sdk";
    version = "0.17.0";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-2I9JWM64pqFNawr6exvQRJ1uOvZ+6J6NZ37JBy2OLFA=";
    };

    dependencies = [
      omnigent-client
      py.prompt-toolkit
      py.pyyaml
      py.rich
    ];

    doCheck = false;

    meta = {
      description = "Terminal UI SDK for Omnigent";
      homepage = "https://omnigent.ai";
      license = lib.licenses.asl20;
    };
  };
in
py.buildPythonApplication rec {
  pname = "omnigent";
  version = "0.17.0";
  format = "wheel";

  # The published wheel ships the prebuilt web SPA under
  # omnigent/server/static/web-ui; the sdist does not.
  src = fetchPypi {
    inherit pname version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-/ygrFeQOlXXilVU5H1zqdYBqR3YVZUo/HlfIfsxR/IQ=";
  };

  # Upper bounds that nixpkgs has already moved past. All of these are
  # conservative caps in omnigent's pyproject, not known incompatibilities.
  pythonRelaxDeps = [
    "argon2-cffi" # nixpkgs 25.1.0 vs <24
    "cachetools" # nixpkgs 7.1.4 vs <7
    "openai" # nixpkgs 2.53.0 vs <2.45
    "packaging" # nixpkgs 26.2 vs <26
    "protobuf" # nixpkgs 7.35.1 vs <7
    "rich" # nixpkgs 15.0.0 vs <15
    "websockets" # nixpkgs 16.1 vs <15
  ];

  dependencies = [
    omnigent-client
    omnigent-ui-sdk
  ]
  ++ (with py; [
    alembic
    anyio
    argon2-cffi
    cachetools
    cel-python
    certifi
    claude-agent-sdk
    click
    fastapi
    filelock
    ftfy
    httpx
    json5
    keyring
    mcp
    openai
    openai-agents
    opentelemetry-api
    opentelemetry-exporter-otlp-proto-grpc
    opentelemetry-exporter-otlp-proto-http
    opentelemetry-instrumentation-fastapi
    opentelemetry-instrumentation-httpx
    opentelemetry-instrumentation-sqlalchemy
    packaging
    pexpect
    pillow
    prompt-toolkit
    protobuf
    psutil
    pydantic
    pyjwt
    pyte
    python-dateutil
    pyyaml
    rich
    sqlalchemy
    starlette
    tiktoken
    tomlkit
    uvicorn
    websockets
    zstandard
  ])
  ++ py.pyjwt.optional-dependencies.crypto
  ++ py.uvicorn.optional-dependencies.standard;

  # The CLI respawns itself as `sys.executable -m omnigent.host._daemon_entry`
  # (cli.py:2945) for the host daemon, and the daemon spawns runners the same
  # way. That is the *bare* interpreter, without the site-dirs that
  # wrapPythonPrograms bakes into the console script, so those children die
  # with ModuleNotFoundError: No module named 'omnigent' and every session hangs
  # on "the connect daemon did not come online within 30s". Hand them the
  # transitive dependency closure through PYTHONPATH, which omnigent's own
  # daemon/runner env allowlist preserves (host/connect.py) while the agent
  # spawn allowlist drops it (inner/agent_env.py), so it never reaches omp.
  postFixup = ''
    buildPythonPath "$out $pythonPath"
    wrapProgram $out/bin/omnigent --prefix PYTHONPATH : "$program_PYTHONPATH"
  '';

  pythonImportsCheck = [
    "omnigent"
    "omnigent_client"
    "omnigent_ui_sdk"
  ];

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Open-source meta-harness giving a common orchestration layer over AI coding agents";
    homepage = "https://omnigent.ai";
    license = lib.licenses.asl20;
    mainProgram = "omnigent";
    platforms = lib.platforms.unix;
  };
}
