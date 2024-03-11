# `Backporter`: script for backports on Julia and external stdlibs

## Setup

```bash
cd /some/path/
git clone https://github.com/KristofferC/Backporter.git

cd /other/path/
git clone git@github.com:JuliaLang/julia.git
# or, for example:
# git clone git@github.com:JuliaLang/Pkg.jl.git
# git clone git@github.com:JuliaSparse/SparseArrays.jl.git
```

## Running the Backporter script

First, get a GitHub PAT (personal access token) from the GitHub website (https://github.com/settings/tokens?type=beta).

Then, run the following commands

```bash
cd /other/path/julia
# or, for example:
# cd /other/path/Pkg.jl
# cd /other/path/SparseArrays

# Set this to the appropiate value.
export BACKPORT_VERSION="1.9"

git checkout "release-${BACKPORT_VERSION:?}"

# The `-b` flag will create the branch only if it doesn't already exist.
git checkout -b "backports-release-${BACKPORT_VERSION:?}"

export GITHUB_AUTH="pasteyourtokenhere"

JULIA_LOAD_PATH="@:@stdlib" julia --project=/some/path/Backporter /some/path/Backporter/backporter.jl
```
