# Package
version       = "0.0.1"
author        = "Zenit Linux"
description   = "zcc - C99-C23 compiler written in Nim, tailored as Nim's C backend"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["zcc"]

# Dependencies
requires "nim >= 2.0.0"

task test, "Run test suite":
  exec "nim c -r tests/run_tests.nim"
