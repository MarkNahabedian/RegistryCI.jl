using HTTP: HTTP

const guideline_registry_consistency_tests_pass = Guideline(;
    info="Registy consistency tests",
    docs=nothing,
    check=(data, guideline_parameters) ->
        meets_registry_consistency_tests_pass(data.registry_head, data.registry_deps),
)

function meets_registry_consistency_tests_pass(
    registry_head::String, registry_deps::Vector{String}
)
    try
        RegistryCI.test(registry_head; registry_deps=registry_deps)
        return true, ""
    catch ex
        @error "" exception = (ex, catch_backtrace())
    end
    return false, "The registry consistency tests failed"
end

const guideline_compat_for_julia = Guideline(;
    info="Compat with upper bound for julia",
    docs=string(
        "There is an upper-bounded `[compat]` entry for `julia` that ",
        "only includes a finite number of breaking releases of Julia.",
    ),
    check=(data, guideline_parameters) ->
        meets_compat_for_julia(data.registry_head, data.pkg, data.version),
)

function meets_compat_for_julia(working_directory::AbstractString, pkg, version)
    package_relpath = get_package_relpath_in_registry(;
        package_name=pkg, registry_path=working_directory
    )
    compat = Pkg.TOML.parsefile(joinpath(working_directory, package_relpath, "Compat.toml"))
    # Go through all the compat entries looking for the julia compat
    # of the new version. When found, test
    # 1. that it is a bounded range,
    # 2. that the upper bound is not 2 or higher,
    # 3. that the range includes at least one 1.x version.
    for version_range in keys(compat)
        if version in Pkg.Types.VersionRange(version_range)
            if haskey(compat[version_range], "julia")
                julia_compat = Pkg.Types.VersionSpec(compat[version_range]["julia"])
                if !isempty(
                    intersect(
                        julia_compat, Pkg.Types.VersionSpec("$(typemax(Base.VInt))-*")
                    ),
                )
                    return false, "The compat entry for `julia` is unbounded."
                elseif !isempty(intersect(julia_compat, Pkg.Types.VersionSpec("2-*")))
                    return false,
                    "The compat entry for `julia` has an upper bound of 2 or higher."
                elseif isempty(intersect(julia_compat, Pkg.Types.VersionSpec("1")))
                    # For completeness, although this seems rather
                    # unlikely to occur.
                    return false,
                    "The compat entry for `julia` doesn't include any 1.x version."
                else
                    return true, ""
                end
            end
        end
    end

    return false, "There is no compat entry for `julia`."
end

const guideline_compat_for_all_deps = Guideline(;
    info="Compat (with upper bound) for all dependencies",
    docs=string(
        "Dependencies: All dependencies should have `[compat]` entries that ",
        "are upper-bounded and only include a finite number of breaking releases. ",
        "For more information, please see the \"Upper-bounded `[compat]` entries\" subsection under \"Additional information\" below.",
    ),
    check=(data, guideline_parameters) ->
        meets_compat_for_all_deps(data.registry_head, data.pkg, data.version),
)

function meets_compat_for_all_deps(working_directory::AbstractString, pkg, version)
    package_relpath = get_package_relpath_in_registry(;
        package_name=pkg, registry_path=working_directory
    )
    deps = Pkg.TOML.parsefile(joinpath(working_directory, package_relpath, "Deps.toml"))
    compat = Pkg.TOML.parsefile(joinpath(working_directory, package_relpath, "Compat.toml"))
    # First, we construct a Dict in which the keys are the package's
    # dependencies, and the value is always false.
    dep_has_compat_with_upper_bound = Dict{String,Bool}()
    for version_range in keys(deps)
        if version in Pkg.Types.VersionRange(version_range)
            for name in keys(deps[version_range])
                if !is_jll_name(name) && !is_julia_stdlib(name)
                    @debug("Found a new (non-stdlib non-JLL) dependency: $(name)")
                    dep_has_compat_with_upper_bound[name] = false
                end
            end
        end
    end
    # Now, we go through all the compat entries. If a dependency has a compat
    # entry with an upper bound, we change the corresponding value in the Dict
    # to true.
    for version_range in keys(compat)
        if version in Pkg.Types.VersionRange(version_range)
            for (name, value) in compat[version_range]
                if value isa Vector
                    if !isempty(value)
                        value_ranges = Pkg.Types.VersionRange.(value)
                        each_range_has_upper_bound = _has_upper_bound.(value_ranges)
                        if all(each_range_has_upper_bound)
                            @debug(
                                "Dependency \"$(name)\" has compat entries that all have upper bounds"
                            )
                            dep_has_compat_with_upper_bound[name] = true
                        end
                    end
                else
                    value_range = Pkg.Types.VersionRange(value)
                    if _has_upper_bound(value_range)
                        @debug(
                            "Dependency \"$(name)\" has a compat entry with an upper bound"
                        )
                        dep_has_compat_with_upper_bound[name] = true
                    end
                end
            end
        end
    end
    meets_this_guideline = all(values(dep_has_compat_with_upper_bound))
    if meets_this_guideline
        return true, ""
    else
        bad_dependencies = Vector{String}()
        for name in keys(dep_has_compat_with_upper_bound)
            if !(dep_has_compat_with_upper_bound[name])
                @error(
                    "Dependency \"$(name)\" does not have a compat entry that has an upper bound"
                )
                push!(bad_dependencies, name)
            end
        end
        sort!(bad_dependencies)
        message = string(
            "The following dependencies do not have a `[compat]` entry ",
            "that is upper-bounded and only includes a finite number ",
            "of breaking releases: ",
            join(bad_dependencies, ", "),
        )
        return false, message
    end
end

const guideline_patch_release_does_not_narrow_julia_compat = Guideline(;
    info="If it is a patch release on a post-1.0 package, then it does not narrow the `[compat]` range for `julia`.",
    check=(data, guideline_parameters) ->
        meets_patch_release_does_not_narrow_julia_compat(
            data.pkg,
            data.version;
            registry_head=data.registry_head,
            registry_master=data.registry_master,
        ),
)

function meets_patch_release_does_not_narrow_julia_compat(
    pkg::String, new_version::VersionNumber; registry_head::String, registry_master::String
)
    old_version = latest_version(pkg, registry_master)
    if old_version.major != new_version.major || old_version.minor != new_version.minor
        # Not a patch release.
        return true, ""
    end
    julia_compats_for_old_version = julia_compat(pkg, old_version, registry_master)
    julia_compats_for_new_version = julia_compat(pkg, new_version, registry_head)
    if Set(julia_compats_for_old_version) == Set(julia_compats_for_new_version)
        return true, ""
    end
    meets_this_guideline = range_did_not_narrow(
        julia_compats_for_old_version, julia_compats_for_new_version
    )
    if meets_this_guideline
        return true, ""
    else
        if (old_version >= v"1") || (new_version >= v"1")
            msg = string(
                "A patch release is not allowed to narrow the ",
                "supported ranges of Julia versions. ",
                "The ranges have changed from ",
                "$(julia_compats_for_old_version) ",
                "(in $(old_version)) ",
                "to $(julia_compats_for_new_version) ",
                "(in $(new_version)).",
            )
            return false, msg
        else
            @info("Narrows Julia compat, but it's OK since package is pre-1.0")
            return true, ""
        end
    end
end

const _AUTOMERGE_NEW_PACKAGE_MINIMUM_NAME_LENGTH = 5

const guideline_name_length = Guideline(;
    info="Name not too short",
    docs="The name is at least $(_AUTOMERGE_NEW_PACKAGE_MINIMUM_NAME_LENGTH) characters long.",
    check=(data, guideline_parameters) -> meets_name_length(data.pkg),
)

function meets_name_length(pkg)
    meets_this_guideline = length(pkg) >= _AUTOMERGE_NEW_PACKAGE_MINIMUM_NAME_LENGTH
    if meets_this_guideline
        return true, ""
    else
        return false,
        "Name is not at least $(_AUTOMERGE_NEW_PACKAGE_MINIMUM_NAME_LENGTH) characters long"
    end
end

const guideline_name_ascii = Guideline(;
    info="Name is composed of ASCII characters only.",
    check=(data, guideline_parameters) -> meets_name_ascii(data.pkg),
)

function meets_name_ascii(pkg)
    if isascii(pkg)
        return true, ""
    else
        return false, "Name is not ASCII"
    end
end

const guideline_julia_name_check = Guideline(;
    info="Name does not include \"julia\" or start with \"Ju\".",
    check=(data, guideline_parameters) -> meets_julia_name_check(data.pkg),
)

function meets_julia_name_check(pkg)
    if occursin("julia", lowercase(pkg))
        return false,
        "Lowercase package name $(lowercase(pkg)) contains the string \"julia\"."
    elseif startswith(pkg, "Ju")
        return false, "Package name starts with \"Ju\"."
    else
        return true, ""
    end
end

damerau_levenshtein(name1, name2) = StringDistances.DamerauLevenshtein()(name1, name2)
function sqrt_normalized_vd(name1, name2)
    return VisualStringDistances.visual_distance(name1, name2; normalize=x -> 5 + sqrt(x))
end

const guideline_distance_check = Guideline(;
    info="Name is not too similar to existing package names",
    docs="""
To prevent confusion between similarly named packages, the names of new packages must also satisfy the following three checks: (for more information, please see the \"Name similarity distance check\" subsection under \"Additional information\" below)
    - the [Damerau–Levenshtein
      distance](https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance)
      between the package name and the name of any existing package must be at
      least 3.
    - the Damerau–Levenshtein distance between the lowercased version of a
      package name and the lowercased version of the name of any existing
      package must be at least 2.
    - and a visual distance from
      [VisualStringDistances.jl](https://github.com/ericphanson/VisualStringDistances.jl)
      between the package name and any existing package must exceeds a certain
      a hand-chosen threshold (currently 2.5).
  """,
    check=(data, guideline_parameters) ->
        meets_distance_check(data.pkg, data.registry_master),
)

function meets_distance_check(
    pkg_name::AbstractString, registry_master::AbstractString; kwargs...
)
    other_packages = get_all_non_jll_package_names(registry_master)
    return meets_distance_check(pkg_name, other_packages; kwargs...)
end

function meets_distance_check(
    pkg_name::AbstractString,
    other_packages::Vector;
    DL_lowercase_cutoff=1,
    DL_cutoff=2,
    sqrt_normalized_vd_cutoff=2.5,
    comment_collapse_cutoff=10,
)
    problem_messages = Tuple{String,Tuple{Float64,Float64,Float64}}[]
    for other_pkg in other_packages
        if pkg_name == other_pkg
            # We short-circuit in this case; more information doesn't help.
            return (false, "Package name already exists in the registry.")
        elseif lowercase(pkg_name) == lowercase(other_pkg)
            # We'll sort this first
            push!(
                problem_messages,
                (
                    "Package name matches existing package name $(other_pkg) up to case.",
                    (0, 0, 0),
                ),
            )
        else
            msg = ""

            # Distance check 1: DL distance
            dl = damerau_levenshtein(pkg_name, other_pkg)
            if dl <= DL_cutoff
                msg = string(
                    msg,
                    " Damerau-Levenshtein distance $dl is at or below cutoff of $(DL_cutoff).",
                )
            end

            # Distance check 2: lowercase DL distance
            dl_lowercase = damerau_levenshtein(lowercase(pkg_name), lowercase(other_pkg))
            if dl_lowercase <= DL_lowercase_cutoff
                msg = string(
                    msg,
                    " Damerau-Levenshtein distance $(dl_lowercase) between lowercased names is at or below cutoff of $(DL_lowercase_cutoff).",
                )
            end

            # Distance check 3: normalized visual distance,
            # gated by a `dl` check for speed.
            if (sqrt_normalized_vd_cutoff > 0 && dl <= 4)
                nrm_vd = sqrt_normalized_vd(pkg_name, other_pkg)
                if nrm_vd <= sqrt_normalized_vd_cutoff
                    msg = string(
                        msg,
                        " Normalized visual distance ",
                        Printf.@sprintf("%.2f", nrm_vd),
                        " is at or below cutoff of ",
                        Printf.@sprintf("%.2f", sqrt_normalized_vd_cutoff),
                        ".",
                    )
                end
            else
                # need to choose something for sorting purposes
                nrm_vd = 10.0
            end

            if msg != ""
                # We must have found a clash.
                push!(
                    problem_messages,
                    (string("Similar to $(other_pkg).", msg), (dl, dl_lowercase, nrm_vd)),
                )
            end
        end
    end

    isempty(problem_messages) && return (true, "")
    sort!(problem_messages; by=Base.tail)
    message = string(
        "Package name similar to $(length(problem_messages)) existing package",
        length(problem_messages) > 1 ? "s" : "",
        ".\n",
    )
    use_spoiler = length(problem_messages) > comment_collapse_cutoff
    # we indent each line by two spaces in all the following
    # so that it nests properly in the outer list.
    if use_spoiler
        message *= """
                     <details>
                     <summary>Similar package names</summary>

                   """
    end
    numbers = string.("  ", 1:length(problem_messages))
    message *= join(join.(zip(numbers, first.(problem_messages)), Ref(". ")), '\n')
    if use_spoiler
        message *= "\n\n  </details>\n"
    end
    return (false, message)
end

const guideline_normal_capitalization = Guideline(;
    info="Normal capitalization",
    docs=string(
        "The package name should start with an upper-case letter, ",
        "contain only ASCII alphanumeric characters, ",
        "and contain at least one lowercase letter.",
    ),
    check=(data, guideline_parameters) ->
        meets_normal_capitalization(data.pkg),
)

function meets_normal_capitalization(pkg)
    meets_this_guideline = occursin(r"^[A-Z]\w*[a-z]\w*[0-9]?$", pkg)
    if meets_this_guideline
        return true, ""
    else
        return false,
        "Name does not meet all of the following: starts with an upper-case letter, ASCII alphanumerics only, not all letters are upper-case."
    end
end

const guideline_repo_url_requirement = Guideline(;
    info="Repo URL ends with `/PackageName.jl.git`.",
    check=(data, guideline_parameters) ->
        meets_repo_url_requirement(data.pkg; registry_head=data.registry_head),
)

function meets_repo_url_requirement(pkg::String; registry_head::String)
    package_relpath = get_package_relpath_in_registry(;
        package_name=pkg, registry_path=registry_head
    )
    package_toml_parsed = Pkg.TOML.parsefile(
        joinpath(registry_head, package_relpath, "Package.toml")
    )

    url = package_toml_parsed["repo"]
    subdir = get(package_toml_parsed, "subdir", "")
    is_subdirectory_package = occursin(r"[A-Za-z0-9]", subdir)
    meets_this_guideline = url_has_correct_ending(url, pkg)

    if is_subdirectory_package
        return true, "" # we do not apply this check if the package is a subdirectory package
    end
    if meets_this_guideline
        return true, ""
    end
    return false, "Repo URL does not end with /name.jl.git, where name is the package name"
end

function _invalid_sequential_version(reason::AbstractString)
    return false, "Does not meet sequential version number guideline: $reason", :invalid
end

function _valid_change(old_version::VersionNumber, new_version::VersionNumber)
    diff = difference(old_version, new_version)
    @debug("Difference between versions: ", old_version, new_version, diff)
    if diff == v"0.0.1"
        return true, "", :patch
    elseif diff == v"0.1.0"
        return true, "", :minor
    elseif diff == v"1.0.0"
        return true, "", :major
    else
        return _invalid_sequential_version("increment is not one of: 0.0.1, 0.1.0, 1.0.0")
    end
end

const guideline_sequential_version_number = Guideline(;
    info="Sequential version number",
    docs=string(
        "Version number: Should be a standard increment and not skip versions. ",
        "This means incrementing the patch/minor/major version with +1 compared to ",
        "previous (if any) releases. ",
        "If, for example, `1.0.0` and `1.1.0` are existing versions, ",
        "valid new versions are `1.0.1`, `1.1.1`, `1.2.0` and `2.0.0`. ",
        "Invalid new versions include `1.0.2` (skips `1.0.1`), ",
        "`1.3.0` (skips `1.2.0`), `3.0.0` (skips `2.0.0`) etc.",
    ),
    check=(data, guideline_parameters) -> meets_sequential_version_number(
        data.pkg,
        data.version;
        registry_head=data.registry_head,
        registry_master=data.registry_master,
    ),
)

function meets_sequential_version_number(
    existing::Vector{VersionNumber}, ver::VersionNumber
)
    always_assert(!isempty(existing))
    if ver in existing
        return _invalid_sequential_version("version $ver already exists")
    end
    issorted(existing) || (existing = sort(existing))
    idx = searchsortedlast(existing, ver)
    idx > 0 || return _invalid_sequential_version(
        "version $ver less than least existing version $(existing[1])"
    )
    prv = existing[idx]
    always_assert(ver != prv)
    nxt = if thismajor(ver) != thismajor(prv)
        nextmajor(prv)
    elseif thisminor(ver) != thisminor(prv)
        nextminor(prv)
    else
        nextpatch(prv)
    end
    ver <= nxt || return _invalid_sequential_version("version $ver skips over $nxt")
    return _valid_change(prv, ver)
end

function meets_sequential_version_number(
    pkg::String, new_version::VersionNumber; registry_head::String, registry_master::String
)
    _all_versions = all_versions(pkg, registry_master)
    return meets_sequential_version_number(_all_versions, new_version)
end

const guideline_standard_initial_version_number = Guideline(;
    info="Standard initial version number. Must be one of: `0.0.1`, `0.1.0`, `1.0.0`, or `X.0.0`.",
    check=(data, guideline_parameters) ->
        meets_standard_initial_version_number(data.version),
)

function meets_standard_initial_version_number(version)
    meets_this_guideline =
        version == v"0.0.1" ||
        version == v"0.1.0" ||
        version == v"1.0.0" ||
        _is_x_0_0(version)
    if meets_this_guideline
        return true, ""
    else
        return false, "Version number is not 0.0.1, 0.1.0, 1.0.0, or X.0.0"
    end
end

function _is_x_0_0(version::VersionNumber)
    result = (version.major >= 1) && (version.minor == 0) && (version.patch == 0)
    return result
end

const guideline_version_number_no_prerelease = Guideline(;
    info="No prerelease data in the version number",
    docs = "Version number is not allowed to contain prerelease data",
    check = data -> meets_version_number_no_prerelease(
        data.version,
    ),
)
const guideline_version_number_no_build = Guideline(;
    info="No build data in the version number",
    docs = "Version number is not allowed to contain build data",
    check = data -> meets_version_number_no_build(
        data.version,
    ),
)
function meets_version_number_no_prerelease(version::VersionNumber)
    if isempty(version.prerelease)
        return true, ""
    else
        return false, "Version number is not allowed to contain prerelease data"
    end
end
function meets_version_number_no_build(version::VersionNumber)
    if isempty(version.build)
        return true, ""
    else
        return false, "Version number is not allowed to contain build data"
    end
end

const guideline_code_can_be_downloaded = Guideline(;
    info="Code can be downloaded.",
    check=(data, guideline_parameters) -> meets_code_can_be_downloaded(
        data.registry_head,
        data.pkg,
        data.version,
        data.pr;
        pkg_code_path=data.pkg_code_path,
    ),
)

function _find_lowercase_duplicates(v)
    elts = Dict{String, String}()
    for x in v
        lower_x = lowercase(x)
        if haskey(elts, lower_x)
            return (elts[lower_x], x)
        else
            elts[lower_x] = x
        end
    end
    return nothing
end

const DISALLOWED_CHARS = ['/', '<', '>', ':', '"', '/', '\\', '|', '?', '*', Char.(0:31)...]

const DISALLOWED_NAMES = ["CON", "PRN", "AUX", "NUL",
                          ("COM$i" for i in 1:9)...,
                          ("LPT$i" for i in 1:9)...]

function meets_file_dir_name_check(name)
    # https://stackoverflow.com/a/31976060
    idx = findfirst(n -> occursin(n, name), DISALLOWED_CHARS)
    if idx !== nothing
        return false, "contains character $(DISALLOWED_CHARS[idx]) which may not be valid as a file or directory name on some platforms"
    end

    base, ext = splitext(name)
    if uppercase(name) in DISALLOWED_NAMES || uppercase(base) in DISALLOWED_NAMES
        return false, "is not allowed"
    end
    if endswith(name, ".") || endswith(name, r"\s")
        return false, "ends with `.` or space"
    end
    return true, ""
end

function meets_src_names_ok(pkg_code_path)
    src = joinpath(pkg_code_path, "src/")
    isdir(src) || return false, "`src` directory not found"
    for (root, dirs, files) in walkdir(src)
        files_dirs = Iterators.flatten((files, dirs))
        result = _find_lowercase_duplicates(files_dirs)
        if result !== nothing
            x = joinpath(root, result[1])
            y = joinpath(root, result[2])
            return false, "Found files or directories in `src` which will cause problems on case insensitive filesystems: `$x` and `$y`"
        end

        for f in files_dirs
            ok, msg = meets_file_dir_name_check(f)
            if !ok
                return false, "the name of file or directory $(joinpath(root, f)) $(msg). This can cause problems on some operating systems or file systems."
            end
        end
    end
    return true, ""
end

const guideline_src_names_OK = Guideline(;
    info="`src` files and directories names are OK",
    check=(data, guideline_parameters) -> meets_src_names_ok(data.pkg_code_path),
)

function meets_code_can_be_downloaded(registry_head, pkg, version, pr; pkg_code_path)
    uuid, package_repo, subdir, tree_hash_from_toml = parse_registry_pkg_info(
        registry_head, pkg, version
    )

    # We get the `tree_hash` two ways and check they agree, which helps ensures the `subdir` parameter is correct. Two ways:
    # 1. By the commit hash in the PR body and the subdir parameter
    # 2. By the tree hash in the Versions.toml

    commit_hash = commit_from_pull_request_body(pr)

    local tree_hash_from_commit, tree_hash_from_commit_success
    clone_success = load_files_from_url_and_tree_hash(
        pkg_code_path, package_repo, tree_hash_from_toml
    ) do dir
        tree_hash_from_commit, tree_hash_from_commit_success = try
            readchomp(Cmd(`git rev-parse $(commit_hash):$(subdir)`; dir=dir)), true
        catch e
            @error e
            "", false
        end
    end

    if !clone_success
        return false, "Cloning repository failed."
    end

    if !tree_hash_from_commit_success
        return false,
        "Could not obtain tree hash from commit hash and subdir parameter. Possibly this indicates that an incorrect `subdir` parameter was passed during registration."
    end

    if tree_hash_from_commit != tree_hash_from_toml
        @error "`tree_hash_from_commit != tree_hash_from_toml`" tree_hash_from_commit tree_hash_from_toml
        return false,
        "Tree hash obtained from the commit message and subdirectory does not match the tree hash in the Versions.toml file. Possibly this indicates that an incorrect `subdir` parameter was passed during registration."
    else
        return true, ""
    end
end

function _generate_pkg_add_command(pkg::String, version::VersionNumber)::String
    return "Pkg.add(Pkg.PackageSpec(name=\"$(pkg)\", version=v\"$(string(version))\"));"
end

is_valid_url(str::AbstractString) = !isempty(HTTP.URI(str).scheme) && isvalid(HTTP.URI(str))

const guideline_version_can_be_pkg_added = Guideline(;
    info="Version can be `Pkg.add`ed",
    docs="Package installation: The package should be installable (`Pkg.add(\"PackageName\")`).",
    check=(data, guideline_parameters) -> meets_version_can_be_pkg_added(
        data.registry_head,
        data.pkg,
        data.version;
        registry_deps=data.registry_deps,
        environment_variables_to_pass=data.environment_variables_to_pass,
    ),
)

function meets_version_can_be_pkg_added(
    working_directory::String,
    pkg::String,
    version::VersionNumber;
    registry_deps::Vector{<:AbstractString}=String[],
    environment_variables_to_pass::Vector{String},
)
    pkg_add_command = _generate_pkg_add_command(pkg, version)
    _registry_deps = convert(Vector{String}, registry_deps)
    _registry_deps_is_valid_url = is_valid_url.(_registry_deps)
    code = """
        import Pkg;
        Pkg.Registry.add(Pkg.RegistrySpec(path=\"$(working_directory)\"));
        _registry_deps = $(_registry_deps);
        _registry_deps_is_valid_url = $(_registry_deps_is_valid_url);
        for i = 1:length(_registry_deps)
            regdep = _registry_deps[i]
            if _registry_deps_is_valid_url[i]
                Pkg.Registry.add(Pkg.RegistrySpec(url = regdep))
            else
                Pkg.Registry.add(regdep)
            end
        end
        @info("Attempting to `Pkg.add` package...");
        $(pkg_add_command)
        @info("Successfully `Pkg.add`ed package");
        """

    cmd_ran_successfully = _run_pkg_commands(
        working_directory,
        pkg,
        version;
        code=code,
        before_message="Attempting to `Pkg.add` the package",
        environment_variables_to_pass=environment_variables_to_pass,
    )
    if cmd_ran_successfully
        @info "Successfully `Pkg.add`ed the package"
        return true, ""
    else
        @error "Was not able to successfully `Pkg.add` the package"
        return false,
        string(
            "I was not able to install the package ",
            "(i.e. `Pkg.add(\"$(pkg)\")` failed). ",
            "See the CI logs for details.",
        )
    end
end

const guideline_version_has_osi_license = Guideline(;
    info="Version has OSI-approved license",
    docs=string(
        "License: The package should have an ",
        "[OSI-approved software license](https://opensource.org/licenses/alphabetical) ",
        "located in the top-level directory of the package code, ",
        "e.g. in a file named `LICENSE` or `LICENSE.md`. ",
        "This check is required for the General registry. ",
        "For other registries, registry maintainers have the option to disable this check.",
    ),
    check=(data, guideline_parameters) ->
        meets_version_has_osi_license(data.pkg; pkg_code_path=data.pkg_code_path),
)

function meets_version_has_osi_license(pkg::String; pkg_code_path)
    pkgdir = pkg_code_path
    if !isdir(pkgdir) || isempty(readdir(pkgdir))
        return false,
        "Could not check license because could not access package code. Perhaps the `can_download_code` check failed earlier."
    end

    license_results = LicenseCheck.find_licenses(pkgdir)

    # Failure mode 1: no licenses
    if isempty(license_results)
        @error "Could not find any licenses"
        return false,
        string(
            "No licenses detected in the package's top-level folder. An OSI-approved license is required.",
        )
    end

    flat_results = [
        (
            filename=lic.license_filename,
            identifier=identifier,
            approved=LicenseCheck.is_osi_approved(identifier),
        ) for lic in license_results for identifier in lic.licenses_found
    ]

    osi_results = [
        string(r.identifier, " license in ", r.filename) for r in flat_results if r.approved
    ]
    non_osi_results = [
        string(r.identifier, " license in ", r.filename) for
        r in flat_results if !r.approved
    ]

    osi_string = string(
        "Found OSI-approved license(s): ", join(osi_results, ", ", ", and "), "."
    )
    non_osi_string = string(
        "Found non-OSI license(s): ", join(non_osi_results, ", ", ", and "), "."
    )

    # Failure mode 2: no OSI-approved licenses, but has some kind of license detected
    if isempty(osi_results)
        @error "Found no OSI-approved licenses" non_osi_string
        return false, string("Found no OSI-approved licenses. ", non_osi_string)
    end

    # Pass: at least one OSI-approved license, possibly other licenses.
    @info "License check passed; results" osi_results non_osi_results
    if !isempty(non_osi_results)
        return true, string(osi_string, " Also ", non_osi_string)
    else
        return true, string(osi_string, " Found no other licenses.")
    end
end

const guideline_version_can_be_imported = Guideline(;
    info="Version can be `import`ed",
    docs="Package loading: The package should be loadable (`import PackageName`).",
    check=(data, guideline_parameters) -> meets_version_can_be_imported(
        data.registry_head,
        data.pkg,
        data.version;
        registry_deps=data.registry_deps,
        environment_variables_to_pass=data.environment_variables_to_pass,
    ),
)

function meets_version_can_be_imported(
    working_directory::String,
    pkg::String,
    version::VersionNumber;
    registry_deps::Vector{<:AbstractString}=String[],
    environment_variables_to_pass::Vector{String},
)
    pkg_add_command = _generate_pkg_add_command(pkg, version)
    _registry_deps = convert(Vector{String}, registry_deps)
    _registry_deps_is_valid_url = is_valid_url.(_registry_deps)
    code = """
        import Pkg;
        Pkg.Registry.add(Pkg.RegistrySpec(path=\"$(working_directory)\"));
        _registry_deps = $(_registry_deps);
        _registry_deps_is_valid_url = $(_registry_deps_is_valid_url);
        for i = 1:length(_registry_deps)
            regdep = _registry_deps[i]
            if _registry_deps_is_valid_url[i]
                Pkg.Registry.add(Pkg.RegistrySpec(url = regdep))
            else
                Pkg.Registry.add(regdep)
            end
        end
        @info("Attempting to `Pkg.add` package...");
        $(pkg_add_command)
        @info("Successfully `Pkg.add`ed package");
        @info("Attempting to `import` package");
        Pkg.precompile()
        import $(pkg);
        @info("Successfully `import`ed package");
        """

    cmd_ran_successfully = _run_pkg_commands(
        working_directory,
        pkg,
        version;
        code=code,
        before_message="Attempting to `import` the package",
        environment_variables_to_pass=environment_variables_to_pass,
    )

    if cmd_ran_successfully
        @info "Successfully `import`ed the package"
        return true, ""
    else
        @error "Was not able to successfully `import` the package"
        return false,
        string(
            "I was not able to load the package ",
            "(i.e. `import $(pkg)` failed). ",
            "See the CI logs for details.",
        )
    end
end

const guideline_linecounts_meet_thresholds = Guideline(;
    info="Test that lines of source, tests and documentation meet specified thresholds",
    docs="""Make sure that various line counts meet or exceed specified thresholds.

 * `src_min_lines`:        Minimum number of lines of source code
 * `readme_min_lines`:     Minimum number of lines in the README file
 * `test_min_lines`:       Minimum number of lines of code in the test directory
 * `doc_min_lines`:        Minimum number of lines of documentation
 * `readme_min_fraction`:  minimum ratio of readme lines to src lines
 * `test_min_fraction`:    minimum ratio of test lines to src lines
 * `doc_min_fraction`:     minimum ratio of doc to src lines

For `test_min_fraction` and `doc_min_fraction`, the denominator of the fraction
also includes the number of lines of test or docs respectively.
""",
    check=(data, guideline_parameters) ->
        linecounts_meet_thresholds(data.pkg_code_path, guideline_parameters)
)

function linecounts_meet_thresholds(pkg_code_path,
                                    guideline_parameters)
    analysis = PackageAnalyzer.analyze(pkg_code_path;)
    # @info analysis
    if isempty(analysis.lines_of_code)
        return false, "PackageAnalyzer didn't find any lines of code."
    end
    # get parameters:
    src_min_lines        = get(guideline_parameters, :src_min_lines,    0)
    readme_min_lines     = get(guideline_parameters, :readme_min_lines, 0)
    test_min_lines       = get(guideline_parameters, :test_min_lines,   0)
    doc_min_lines        = get(guideline_parameters, :doc_min_lines,    0)
    readme_min_fraction  = get(guideline_parameters, :readme_min_fraction, 0.0)
    test_min_fraction    = get(guideline_parameters, :test_min_fraction,   0.0)
    doc_min_fraction     = get(guideline_parameters, :doc_min_fraction,    0.0)
    issues = []
    src_line_count = PackageAnalyzer.count_julia_loc(analysis, "src")
    test_line_count = PackageAnalyzer.count_julia_loc(analysis, "test")
    docs_line_count = PackageAnalyzer.count_docs(analysis)
    readme_line_count = PackageAnalyzer.count_readme(analysis)

    function check_count(desc, got, want)
        if got < want
            push!(issues, "Too few lines of $desc: $got, where $want is required.")
        end
    end
    check_count("source code", src_line_count, src_min_lines)
    check_count("README file", readme_line_count, readme_min_lines)
    check_count("test code", test_line_count, test_min_lines)
    # Some projects might put adequate documentation in their README
    # file and not have any other documentation.
    check_count("documentation",
                max(readme_line_count, docs_line_count),
                doc_min_lines)
    function check_fraction(desc, got, want)
        if got < want
            push!(issues,
                  @sprintf("The ratio of %s is less than required: %1.2f%% versus %1.2f%%.",
                           desc, 100 * got, 100 * want))
        end
    end
    check_fraction("README lines to source code",
                   readme_line_count / src_line_count, readme_min_fraction)
    check_fraction("test lines to test plus src lines",
                   test_line_count / (test_line_count + src_line_count),
                   test_min_fraction)
    # See the comment above regarding README vs. docs.
    check_fraction("documentation lines to documentation plus src lines",
                   max(readme_line_count, docs_line_count) /
                       (docs_line_count + src_line_count),
                   doc_min_fraction)
    if isempty(issues)
        return true, ""
    else
        return false, join(issues, "\n")
    end
end


function _run_pkg_commands(
    working_directory::String,
    pkg::String,
    version::VersionNumber;
    code,
    before_message,
    environment_variables_to_pass::Vector{String},
)
    original_directory = pwd()
    tmp_dir_1 = mktempdir()
    atexit(() -> rm(tmp_dir_1; force=true, recursive=true))
    cd(tmp_dir_1)
    # We need to be careful with what environment variables we pass to the child
    # process. For example, we don't want to pass an environment variable containing
    # our GitHub token to the child process. Because if the Julia package that we are
    # testing has malicious code in its __init__() function, it could try to steal
    # our token. So we only pass these environment variables:
    # 1. HTTP_PROXY. If it's set, it is delegated to the child process.
    # 2. HTTPS_PROXY. If it's set, it is delegated to the child process.
    # 3. JULIA_DEPOT_PATH. We set JULIA_DEPOT_PATH to the temporary directory that
    #    we created. This is because we don't want the child process using our
    #    real Julia depot. So we set up a fake depot for the child process to use.
    # 4. JULIA_PKG_SERVER. If it's set, it is delegated to the child process.
    # 5. JULIA_REGISTRYCI_AUTOMERGE. We set JULIA_REGISTRYCI_AUTOMERGE to "true".
    # 6. PATH. If we don't pass PATH, things break. And PATH should not contain any
    #    sensitive information.
    # 7. PYTHON. We set PYTHON to the empty string. This forces any packages that use
    #    PyCall to install their own version of Python instead of using the system
    #    Python.
    # 8. R_HOME. We set R_HOME to "*".
    # 9. HOME. Lots of things need HOME.
    #
    # If registry maintainers need additional environment variables to be passed
    # to the child process, they can do so by providing the `environment_variables_to_pass`
    # kwarg to the `AutoMerge.run` function.

    env = Dict(
        "JULIA_DEPOT_PATH" => mktempdir(),
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        "JULIA_REGISTRYCI_AUTOMERGE" => "true",
        "PYTHON" => "",
        "R_HOME" => "*",
    )
    default_environment_variables_to_pass = [
        "HOME",
        "JULIA_PKG_SERVER",
        "PATH",
        "HTTP_PROXY",
        "HTTPS_PROXY",
    ]
    all_environment_variables_to_pass = vcat(
        default_environment_variables_to_pass,
        environment_variables_to_pass,
    )
    for k in all_environment_variables_to_pass
        if haskey(ENV, k)
            env[k] = ENV[k]
        end
    end

    cmd = Cmd(`$(Base.julia_cmd()) -e $(code)`; env=env)

    # GUI toolkits may need a display just to load the package
    xvfb = Sys.which("xvfb-run")
    @info("xvfb: ", xvfb)
    if xvfb !== nothing
        pushfirst!(cmd.exec, "-a")
        pushfirst!(cmd.exec, xvfb)
    end
    @info(before_message)
    cmd_ran_successfully = success(pipeline(cmd; stdout=stdout, stderr=stderr))
    cd(original_directory)

    rmdir(tmp_dir_1)

    return cmd_ran_successfully
end

function rmdir(dir)
    try
        chmod(dir, 0o700; recursive=true)
    catch
    end
    return rm(dir; force=true, recursive=true)
end

url_has_correct_ending(url, pkg) = endswith(url, "/$(pkg).jl.git")

function get_automerge_guidelines(
    ::NewPackage;
    check_license::Bool,
    this_is_jll_package::Bool,
    this_pr_can_use_special_jll_exceptions::Bool,
)
    guidelines = [
        (guideline_registry_consistency_tests_pass, true),
        (guideline_pr_only_changes_allowed_files, true),
        # (guideline_only_changes_specified_package, true), # not yet implemented
        (guideline_normal_capitalization, !this_pr_can_use_special_jll_exceptions),
        (guideline_name_length, !this_pr_can_use_special_jll_exceptions),
        (guideline_julia_name_check, true),
        (guideline_repo_url_requirement, true),
        (guideline_version_number_no_prerelease, true),
        (guideline_version_number_no_build, !this_pr_can_use_special_jll_exceptions),
        (guideline_compat_for_julia, true),
        (guideline_compat_for_all_deps, true),
        (guideline_allowed_jll_nonrecursive_dependencies, this_is_jll_package),
        (guideline_name_ascii, true),
        (:update_status, true),
        (guideline_version_can_be_pkg_added, true),
        (guideline_code_can_be_downloaded, true),
        # `guideline_version_has_osi_license` must be run
        # after `guideline_code_can_be_downloaded` so
        # that it can use the downloaded code!
        (guideline_version_has_osi_license, check_license),
        (guideline_src_names_OK, true),
        (guideline_version_can_be_imported, true),
        (:update_status, true),
        (guideline_dependency_confusion, true),
        # We always run the `guideline_distance_check`
        # check last, because if the check fails, it
        # prints the list of similar package names in
        # the automerge comment. To make the comment easy
        # to read, we want this list to be at the end.
        (guideline_distance_check, true),
    ]
    return guidelines
end

function get_automerge_guidelines(
    ::NewVersion;
    check_license::Bool,
    this_is_jll_package::Bool,
    this_pr_can_use_special_jll_exceptions::Bool,
)
    guidelines = [
        (guideline_registry_consistency_tests_pass, true),
        (guideline_pr_only_changes_allowed_files, true),
        (guideline_sequential_version_number, !this_pr_can_use_special_jll_exceptions),
        (guideline_version_number_no_prerelease, true),
        (guideline_version_number_no_build, !this_pr_can_use_special_jll_exceptions),
        (guideline_compat_for_julia, true),
        (guideline_compat_for_all_deps, true),
        (
            guideline_patch_release_does_not_narrow_julia_compat,
            !this_pr_can_use_special_jll_exceptions,
        ),
        (guideline_allowed_jll_nonrecursive_dependencies, this_is_jll_package),
        (:update_status, true),
        (guideline_version_can_be_pkg_added, true),
        (guideline_code_can_be_downloaded, true),
        # `guideline_version_has_osi_license` must be run
        # after `guideline_code_can_be_downloaded` so
        # that it can use the downloaded code!
        (guideline_version_has_osi_license, check_license),
        (guideline_src_names_OK, true),
        (guideline_version_can_be_imported, true),
    ]
    return guidelines
end
