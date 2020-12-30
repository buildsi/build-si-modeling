# The Spec: Spack's dependency model

## Spec syntax
* Syntax for constraints on Spec DAGs on command line
* Query specs, specs as "matchers"

## Nodes
* Name
* Variants
* Compiler (to be deleted)
* Platform
* OS (can go away once we model libc?)
  * Cosmopolitan libc for OS portability: https://justine.lol/cosmopolitan/index.html
* Target
  * How can target affect dependency constraints?
    * lib64 vs lib
  * May include 32 or non-32 compat, x32?
* Flags

## Dependencies (Edges)
* Types of dependencies
  * Build
    * At build time:
      * Must exist
      * Add to PATH
    * Dependencies of build deps don't need to be unified with other build deps of same parent (not true right now)
    * Can be removed ater build completes (parent doesn't need it after build time)
  * Link
    * Currently models dynamic libs
    * Dynamic library
    * Must be in same process 
    * Adds -L to compiler wrappers
    * Adds -Wl,-rpath to compiler wrappers
    * Adds transitive RPATHs if not specified otherwise
    * Could pre-resolve to absolute DT_NEEDED path
      * May conflict with dlopen
    * May be subsumed by another library given compatible ABI
    * Needs to stick around after build (can't be uninstalled w/o parent uninstalled)
    * Decisions at link time affect how the spec can be executed at runtime.
  * Run
    * Program will call executables from this at runtime
    * Usually by name (so relies on PATH, has to be unified)
    * Needs to stick around after build (parent needs it)
  * Test
    * Needed at test time, probably need way more fleshing out
    * Probably need test-build, test-run, test-link, test-include deps
    * Maybe needs to be re-envisioned as a crosscut
  * Deptypes we do not currently have
    * Include? Header-only?
      * Has to be unified so everyone gets same headers
      * Doesn't need to be kept around for dependents after build time
    * Interface?
    * Static linking
* Finer-grained types?
  * Linking: static vs. dynamic?  Static pic?
  * The above dependency types can be viewed as umbrellas of finer-grained types: https://github.com/spack/spack/discussions/20523.
* Weird dependency types that need to be in the taxonomy somewhere
  * Libc (sets interpreter)
  * Allocator (tcmalloc, supposed to be statically linked)
  * LD_PRELOAD and other shims
  * Load time issues related to libraries and subsuming APIs etc.
    * Rust in jemalloc mixed with a libc application, have to link/preload jemalloc?
    * Discuss windows loading model
    * Language requirements of loaders
    * Consider behavior of DYLD_FALLBACK_LIBRARY_PATH

## Virtual dependencies
* These are currently very nonspecific   it's possible these could be fungible with [weird dependency types above](https://github.com/spack/spack/discussions/20256#discussioncomment-248934).
  * These do not attempt to validate any properties about implementors.
* Consider this from the context of:
  * Package declares virtual dep (in package.py)
  * User specifies virtual dep (on CLI)
* Supposed to model interfaces at the API level
  * Currently we only resolve versions on virtual dependencies
  * Variants could happen too
  * Not sure target, os, compiler, etc. make sense on vspecs
  * Nothing to do with ABI yet -- should virtuals have ABI specs or is that really an attribute of the concrete dependencies (I think it is)

# Unification constraints (from the build and run environments)

## Contexts (processes)
  * Determined by dependency type
    * Build dependencies imply process (and thus context) boundaries
    * Run implies process boundary as well
  * Granularity of unification
  * Binary dependencies / Explicit sandboxing can affect this
    * Binary dependencies = built on another machine

## Unified constraints bt/w build and run environment
  * Python versions need to match with setuptools b/c setuptools generates code for the run env
  * Variants may need to match
    * Encoding must match bt/w build and run python
    * TCE vs RHEL python -- different encodings on TOSS
      * Flux build issues

## PATH-based constraints [tweet](https://twitter.com/tgamblin/status/1343630959673950208)
  * PATH - requires unification of deps IF things don't invoke programs via abspaths
    * Most things don't use abspath
  * Other search paths

## PATH has to be unified for build dependencies of the same package

## Linker constraints:
  * Relying on LD_LIBRARY_PATH means libs have to be unified for any root of a link context
  * Using RPATH you can have different packages that rely on different versions of libraries in the same environment
    * This can be avoided with symbol rewrite methods that don't yet exist: https://twitter.com/hipsterelectron/status/1342556057474756608?s=20 
    * This can be detected beforehand by scanning exported symbols.
    * This has analogies for non-C-ABI languages (e.g. python).

## Environments
  * What are they?
    * How/Can these be serialized?
    * How do these differ from (spack) modules?
  * Shell session?
  * Shared env vars with common parent process?

## Loading mechanisms and how they affect model constraints
  * Python namespace conflicts in PYTHONPATH
    * Multiple python binaries can exist in the same environment with e.g. PEX https://github.com/spack/spack/issues/20430.
    * PEP 420 namespace packages: https://www.python.org/dev/peps/pep-0420/
  * __init__.py files and namespace packages vs. regular packages --> unification constraints
  * How do mechanisms affect composability of packages
  * It's possible to specify this in a language-independent way, with some caveats.
    * "unified import path" assumption in python vs npm and node_modules
  * FUSE: https://github.com/spack/spack/issues/20359
  * Sandboxing: https://github.com/spack/spack/issues/20260

## Npm and node modules
  * Allowing multiple versions of packages
  * Code bloat in browsers
  * Minimization? (nothing does this AFAIK)

# Tangents
* Modules
* Rpath using a view?
  * Death by inodes
  * https://github.com/spack/spack/issues/20359 with FUSE
* Parametrizing distros
  * Portage https://wiki.gentoo.org/wiki/Portage
    * Musl gentoo: https://wiki.gentoo.org/wiki/Project:Hardened_musl
    * Uclibc gentoo: https://wiki.gentoo.org/wiki/Project:Hardened_uClibc
  * Void linux https://voidlinux.org
  * Can this be applied to arbitrary "environments"? Can this be overridden for specializations of distros?
* Loading without symbol conflicts, only works for loading audit libs it seems: LD_AUDIT: https://man7.org/linux/man-pages/man8/ld.so.8.html
* Spack bootstrapping binaries:
  * Clingo
  * python

# Solving complexity -- progression of concretizer models
* Greedy concretizer
  * No backtracking, gets a lot of things wrong
  * Is wrong
* New concretizer
  * Full backtracking
  * Compilers modeled as attributes
  * Doesn't consider ABI or alternate dependencies
  * Forces you to run with what you built with
* Prefer installed packages
  * Still forced to run with what you built with (hdf5 has to use link dependencies from build time)
  * Can maximize reuse of concrete spec hashes (already-installed or binary packages)
* Separate contexts for build dependencies
  * Don't unify entire DAG
  * Allow build deps of packages to differ
  * Minimize number of unique builds across all contexts
  * Enforce build-time <--> run-time constraints
    * See code generation above (python version sync, etc.)
* Compilers (runtimes? Allocators? Init/start blocks(crt0.o)?) as dependencies
  * Uses separate contexts and adds synthetic nodes for runtimes like libstdc++
    * How do "synthetic nodes" differ from virtual dependencies?
* More flexible deploy model
  * Relax constraint that you must run with the libs you built with
  * Allow, e.g., zlib to be swapped for a new version w/o rebuilding dependents
  * Swap a new hdf5 node into an existing build w/o swapping its dependencies in
  * Etc.
  * Much more combinatorial b/c root no longer implies specific dep hashes
* Add ABI checking
  * What other concepts (e.g. script locations) might be analogous to ABI?
  * Add ABI description to every node
  * Evaluate ABI compatibility like we would version compatibility 
  * Do all exit calls of dependents match entry calls of dependencies?
  * Find ABI-compatible configuration, maximizing reuse of installed binaries, etc.
* Really fine-grained: https://github.com/spack/spack/issues/20607 describes changes made to concretizer in order

# Composition
* Dependency relationships
  * Link libraries
  * Run programs
* Dlopen
* Swap chunks of a DAG in and out
  * Binary packages, choosing ABI-compatible ones
* Bindmount libraries into containers
  * Verify ABI compatibility of sub-DAG from host with binaries in container ecosystem
* Constraints affect what we can/can't compose
  * Constraints can relate any two (more?) packages to each other
  * Don't have to follow strict dependency relationships
* Bootstrapping a new thing in an old ecosystem
  * What parts to reuse?
  * What are the tradeoffs?

# Best practices guide
* LDRD committee wants best practices guide for software maintainers rooted in this type of model
* Compiler/runtime compatibility probably factors in
* Need to get it done by initial review in march
* Todd's thoughts:
  * we should tie things in the guide back to our model and how they manifest in spack
  * Model isn't integral to this guide but keep it in mind
  * Should probably keep Rob Blake's presentation on dev workflows in mind as a use case
  * Might be able to use that + other teams' (MARBL?) workflows as a basis
  * Should identify what things currently suck about working on large software projects, what we want to fix, and how that improves developers lives/saves time
  * Maybe quantify some of this, e.g.:
    * "currently we waste X number of hours dealing with this issue that we can't yet reason about b/c we haven't modeled it.
    * "if we had this type of resolver/checking, we could reuse system packages and save X number of hours"

# Papers
* We need to write papers on this stuff, and I think they could be really good
* Something at USENIX about the origins of all these issues in modern software and how they affect composability and build system construction
* How we can reason about all the aspects w/solvers
* Formal descriptions of the model
* Sometimes hard for me to know as an HPC person what a "contribution" looks like at ICSE, USENIX, PLDI, etc. but I think there are fundamental things in here and we can work it out.

