* [*Overview*](https://github.com/spack/spack/discussions/20256#discussioncomment-248938)
* *Definitions all conform to the ones in [Workflows](https://spack.readthedocs.io/en/latest/workflows.html#package-concrete-spec-installed-package).*

# Use Cases
* Concepts in this doc should map back to a specific requirement from some use case:
  1. spack *user*
  1. spack *package developer*
  1. spack *maintainer*
* A single person may represent any of these use cases at different moments.
* [Workflows](https://spack.readthedocs.io/en/latest/workflows.html) will implicitly involve input from all of these use cases.

The below example attempts to demonstrate how users, package developers, and maintainers interact in a **non-Spack context**:

## Example: Pip Floating Constraints
[@vsoch](https://github.com/spack/build-si-modeling/issues/1#issuecomment-758894855):
> This is a huge human element in this process that can lead to the solver failing (e.g., pip) when the constraints are too strict.

Yes!!! I think this is a really crucial point.

Developers of large python libraries like tensorflow will leave some dependencies like Werkzeug with completely floating versions to avoid introducing transitive build failures, preferring to push the work onto dependees to find out the true value of that floating constraint (because tensorflow is *NOT* compatible with every single version of werkzeug). If you upload a new version of said constraint? Pip will then **immediately** start using that version, and your CI failures start depending upon the time of day, and a sad developer will spend several hours finding the right packages to delete each time.

So in this case, we get it **totally backwards from the ideal case**, because it's very easy for python repo maintainers to upload new packages to test, but downstream users are having CI fail when that happens.

See this happen in the wild with Anaconda:
https://stackoverflow.com/questions/48311645/installing-tensorflow-using-pip-within-anaconda-fails

### Example: Composing Environments for Polynomial Solves

A solution Twitter once had was a partitioning-based constraint solver which kept track of all available versions of each target, using a union-find as well as locally merging constraint requirements. This is described because it introduces the concept of *merging* which is adapted here in [filesystem operations](#filesystem-operations). It was never used in production.

[pants](https://github.com/pantsbuild/pants) lets you organize and publish your python code into multiple independent wheels published to PyPI. My technique created a pip lockfile for every root python project, then propagated matching requirement constraints back up to parent libraries, all the way up to the dependency roots. This amortized the cost of having to actually ping PyPI for new requirements to occur literally only when a single conflict was found. More importantly, this process separated for the first time the user and maintainer UX, where *users* have no responsibilities and don't wait very long, and *maintainers* are responsible for using *domain knowledge* to make a requirement update go as smoothly as possible (with as few one-off hacks as possible):
- *user*: pulls master. makes changes to source code.
    - if no changes to requirements, then the install is retrieved from cache (instant).
    - if requirements change on some maybe-root target, a lockfile is generated for that target, and then that lockfile is used to resolve and populate the cache. This lockfile can then be propagated back *down* to all roots.
- *maintainer*: "ok, someone wants to update this dependency, i'll figure out how to make that work."
    - Applies a diff that bumps tensorflow to version 2 (this would be done by a member on the machine learning team).
    - Re-run pip (in parallel) over every root target again, and merge those constraints up to recursive parents when possible (does not hit the internet).
    - For each case where merging constraints produces an empty `VersionRange`, that implies a contradiction has occurred.
    - Scan pypi for all nearby applicable (according to platform) versions of the package, and attempts to find a neighborhood around the previous `VersionRange` value of that constraints which *does* confirm to the requirements.
    - For all cases where this automatic local search fails, create a pants target which points back to the previous requirement version, before updating it, and point all such cases to the old requirement version. These are considered TODOs.

So after spending some *pants developer* time, we were able to make the user UX **strictly better than pip**, and we developed a runbook which I hope means users with domain experience (aka *maintainers*) no longer have to do anything in their head except focus purely on the spots that weren't fixed automatically.

# The Spec: Spack's dependency model

* *Definitions all conform to the ones in [Workflows](https://spack.readthedocs.io/en/latest/workflows.html#package-concrete-spec-installed-package).*
* The Spack Spec defines the atomic elements that Spack can use to define [*environment constraints*](#unified-constraints).

## Common to All Use Cases
### Spec Nodes
A spec may contain the following labeled values:

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
* Checksum

### Filesystem
* A tree, where non-leaf nodes are called *directories* and leaves are *files*.
* A *file* is a string of bytes.
  * Each file can be indexed by its path.
* **There is a single global mutable filesystem at all times.**
  * TODO this could be challenged via [sandboxing](#sandboxing).

#### Filesystem Operations
* Filesystems can be:
  1. *merged* with another filesystem to produce a new filesystem.
    * This is **not invertible** in general [^view-command]:

> If the set of packages being included in a view is inconsistent, then it is possible that two packages will provide the same file. Any conflicts of this type are handled on a first-come-first-served basis, and a warning is printed.

  2. *archived* into a *file*.
    * This is always **invertible**.

#### Unified Environment
* **Environment variables also satisfy the above definition of a *filesystem*!**

### Abstract vs Concrete
* Users specify [abstract specs][^abstract-specs] to Spack.
  * A spec is *concrete* if the checksum is specified.
  * Otherwise, it is *abstract*.

### Concretization
* *Concretization* evaluates a set of [*unification constraints*](#unification-constraints) against a set of [repos](#package-repositories) to produce a [*build plan*](#build-plan) which produces a [*unified environment*](#unified-environment) satisfying all constraints.
  * This process may result in an error.

## User Concepts
### Package Repositories
* As per [Package Repositories][^package-repositories], a *package repository* or *repo* is an **index of [package](#package) versions by name**.

#### `package.py`

* As per [Workflows](https://spack.readthedocs.io/en/latest/workflows.html#package-concrete-spec-installed-package), a [*package*](#package) is a recipe to build one piece of software, specified in a `package.py` file.
    * A `package.py` is always in some [*repo*](#package-repositories).

### Commands

* Users interact with Spack by running *commands* which accept a list of [*abstract specs*][^abstract-specs]:
  * `concretize`: figure out a [build plan](#build-plan) for all the abstract specs to produce a list of [*concrete specs*](#abstract-vs-concrete).
  * `install`: execute the build plan from `concretize` so all concrete specs are [*built*](#build-plan) into a *directory*.
  * `activate`: perform [*environment modifications*](#environment-modifications) for the [concretized](#concretization) version of all abstract specs provided.
    * This corresponds to [*global activation*][^global-activation] specifically.
    * This abstract action covers the act of *creating a non-global filesystem view* as well.
    * The input here may come as a *module*.
* Spack also has many other commands which affect the output of these commands, but WOLOG they can be ignored.

#### Spec syntax
* Syntax for constraints on Spec DAGs on command line
* Query specs, specs as "matchers"

<!-- **A spec is an index into an "environment"** -->

#### Build Phases
* Spack defines several *build phases* which may or may not execute for some [package](#package), depending on the user-selected spack command.
  * *See [supported spack workflows](https://spack.readthedocs.io/en/latest/workflows.html).*

| type  | availability                                       | components                           | propagates |
| ---   | ---                                                | ---                                  | ---        |
| build | build time, not runtime                            | Unknown                              | no         |
| link  | build time, also implies run and test time for now | Unknown, probably includes a library | yes        |
| run   | all of build, link run and test                    | Unknown                              | yes        |
| test  | test build and run time, maybe normal build        | Unknown                              | no         |

* Each *build phase* acts upon a [unified environment](#unified-environment), and consists of:
  1. applying the appropriate [*environment modifications*](#environment-modifications).
  1. arbitrary work that modifies the *filesystem*.

##### Build Plan
* A *build plan* is an ordered list of *build phases*.

### Environments
*From [Environments](https://spack.readthedocs.io/en/latest/environments.html):*
> An environment is used to group together a set of specs for the purpose of building, rebuilding and deploying in a coherent fashion.

* A *spack environment*
* What are they?
  * How/Can these be serialized?
  * How do these differ from (spack) modules?
* Shell session?
* Shared env vars with common parent process?

## Package Developer Concepts

### Package
As per [Workflows](https://spack.readthedocs.io/en/latest/workflows.html#package-concrete-spec-installed-package), a *package* is a recipe to build one piece of software, containing:
1. a mapping of version string to *package source*:
  * **a package source will always resolve to a specific checksum**, but that checksum may change e.g. if it points to a git branch.
  * a package source can be *unpacked* into a directory to modify the user's filesystem.
1. a collection of specs representing the package's dependencies.
  * these describe the dependencies for all versions of the package.
    * e.g. these may contain *conditional dependencies*, which are [unified](#unified-constraints) during concretization.
1. implementations for [build phases](#build-phases).
1. any [environment modifications](#environment-modifications).

These are always specified in a [`package.py`](#package-py) file in some [repo](#package-repositories).

#### Environment Modifications
* As per [unified environment](#unified-environment), the process environment can be treated as its own global *filesystem*.

### Dependency Types

Current dependency types:

* Dependencies represent [implicit requirements](#implicit-requirements).
* Currently, packages may *declare* either an [explicit](#explicit-dependencies) or [virtual](#virtual-dependendencies) dependency.
  * These declared dependencies are intended to **satisfy implicit requirements**.

#### Explicit Dependencies
* An *explicit* dependency is a **human package developer's attempt** to satisfy any number of *implicit* requirements.
  * *This description is based on [this model](https://github.com/spack/spack/discussions/20256#discussioncomment-248938).*
* Currently, spack **conflates** *dependency types* with [build phases](#build-phases):
  * The *dependency types* corresponding to each *build phase* can be viewed as **umbrellas** of implicit requirements.

#### Implicit Requirements
The known types of implicit requirements, sorted by the type of explicit dependency which is currently used to satisfy it:

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

##### TODO Implicit Requirements

* PATHs required by a given phase
* Components used, probably by phase:
  * commands? might be covered by paths
  * interface: headers/modules/definitions that are needed at build but not runtime
  * libraries: possibly also static vs dynamic
* Linking: static vs. dynamic? Static pic?
* propagation: in A->B->C does A depend on C in a given phase
* Does it have ABI impact?
* Weird types of  that need to be in the taxonomy somewhere:
  * Libc (sets interpreter)
  * Allocator (tcmalloc, supposed to be statically linked)
  * LD_PRELOAD and other shims
  * Load time issues related to libraries and subsuming APIs etc.
    * Rust in jemalloc mixed with a libc application, have to link/preload jemalloc?
    * Discuss windows loading model
    * Language requirements of loaders
    * Consider behavior of DYLD_FALLBACK_LIBRARY_PATH

#### Virtual dependencies
* A *virtual* dependency is spack's current encoding of *implicit* requirements.
  * These **currently do not attempt to validate** any properties about implementors.
* Supposed to model *interfaces* at the API level
  * Currently we only resolve versions on virtual dependencies
  * Variants could happen too
  * Not sure target, os, compiler, etc. make sense on vspecs
  * Nothing to do with ABI yet -- should virtuals have ABI specs or is that really an attribute of the concrete dependencies (I think it is)

## Maintainer Concepts

These are concepts that should be relevant for Spack implementation.

### Unification Constraints
* The runtime environment imposes many constraints on the build-time environment, e.g.:
    * Python versions need to match with setuptools b/c setuptools generates code for the run env
    * Variants may need to match
      * Encoding must match bt/w build and run python
      * TCE vs RHEL python -- different encodings on TOSS
        * Flux build issues

#### PATH-based constraints [tweet](https://twitter.com/tgamblin/status/1343630959673950208)
  * PATH - requires unification of deps IF things don't invoke programs via abspaths
    * Most things don't use abspath
  * Other search paths

#### PATH has to be unified for build dependencies of the same package

#### Linker constraints:
  * Relying on LD_LIBRARY_PATH means libs have to be unified for any root of a link context
  * Using RPATH you can have different packages that rely on different versions of libraries in the same environment
    * This can be avoided with symbol rewrite methods that don't yet exist: https://twitter.com/hipsterelectron/status/1342556057474756608?s=20
    * This can be detected beforehand by scanning exported symbols.
    * This has analogies for non-C-ABI languages (e.g. python).

# Spack Implementation

* Spack currently uses [*contexts*](#contexts) **to represent state**.
* Spack's limitations on the [above dependency model](#the-spec-spack-s-dependency-model) have decreased as [model complexity](#model-complexity) has increased.

## Contexts
* A *context* is the [*unified environment*](#unified-environment) in which a [*build phase*](#build-phase) is executed.
  * Determined by dependency type
    * Build dependencies imply process (and thus context) boundaries
    * Run implies process boundary as well
  * Granularity of unification
  * Binary dependencies / Explicit sandboxing can affect this
    * Binary dependencies = built on another machine

### Loading mechanisms and how they affect model constraints
  * Python namespace conflicts in PYTHONPATH
    * Multiple python binaries can exist in the same environment with e.g. PEX https://github.com/spack/spack/issues/20430.
    * PEP 420 namespace packages: https://www.python.org/dev/peps/pep-0420/
  * __init__.py files and namespace packages vs. regular packages --> unification constraints
  * How do mechanisms affect composability of packages
  * It's possible to specify this in a language-independent way, with some caveats.
    * "unified import path" assumption in python vs npm and node_modules
  * FUSE: https://github.com/spack/spack/issues/20359
  * [Sandboxing](#sandboxing)

### Sandboxing
See https://github.com/spack/spack/issues/20260.

## Model Complexity
*This describes the progression of concretizer models.*
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
    * *Not necessarily -- consider **user** vs **maintainer** workflows as in [Use Cases](#use-cases).*
* Add ABI checking
  * What other concepts (e.g. script locations) might be analogous to ABI?
  * Add ABI description to every node
  * Evaluate ABI compatibility like we would version compatibility
  * Do all exit calls of dependents match entry calls of dependencies?
  * Find ABI-compatible configuration, maximizing reuse of installed binaries, etc.
* *Really fine-grained: https://github.com/spack/spack/issues/20607 describes changes made to concretizer in order*

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

## Npm and node modules
  * Allowing multiple versions of packages
  * Code bloat in browsers
  * Minimization? (nothing does this AFAIK)

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
  * Should identify:
    * [who is working on large software projects](#use-cases),
    * what things currently suck about working on large software projects
      * *e.g. [the pip example](#example-pip-floating-constraints)*
      * "currently we waste X number of hours dealing with this issue that we can't yet reason about b/c we haven't modeled it.
    * what we want to fix,
    * how that improves developers lives/saves time!
      * "if we had this type of resolver/checking, we could reuse system packages and save X number of hours"
      * e.g. [the pip example solution](#example-composing-environments-for-polynomial-solves)

# Papers
* We need to write papers on this stuff, and I think they could be really good
* Something at USENIX about the origins of all these issues in modern software and how they affect composability and build system construction
* How we can reason about all the aspects w/solvers
* Formal descriptions of the model
* Sometimes hard for me to know as an HPC person what a "contribution" looks like at ICSE, USENIX, PLDI, etc. but I think there are fundamental things in here and we can work it out.

# Footnotes

[^package-repositories]: https://spack.readthedocs.io/en/latest/repositories.html
[^abstract-specs]: https://spack.readthedocs.io/en/latest/environments.html#adding-abstract-specs
[^view-command]: https://spack.readthedocs.io/en/latest/workflows.html#spack-view
[^global-activation]: https://spack.readthedocs.io/en/latest/basic_usage.html#activating-extensions-globally
