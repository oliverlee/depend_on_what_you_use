"""
Example of a source-modifying aspect applying the fixes reported by a DWYU aspect.

The aspect requires a DWYU aspect and runs one fix action per target. The action
reads the DWYU report of the target and edits the BUILD file of the target with
buildozer.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

# For T fixed targets and H headers in the build, `map_each` costs O(T * H)
# Starlark calls, while formatting the lines in the provider costs O(H).
_HeaderOwnerInfo = provider(
    doc = "Headers in the dependency closure of a target and the target owning each header.",
    fields = {
        "header_owners": "depset of '<header path> <owner label>' lines",
    },
)

def _deps(ctx):
    return [
        dep
        for attr in ctx.attr._deps_attrs
        for dep in getattr(ctx.rule.attr, attr, [])
        if _HeaderOwnerInfo in dep
    ]

def _dep_header_owners(ctx):
    return depset(
        transitive = [
            dep[_HeaderOwnerInfo].header_owners
            for dep in _deps(ctx)
        ],
    )

def _header_owner_info(target, ctx):
    compilation_context = target[CcInfo].compilation_context
    return _HeaderOwnerInfo(
        header_owners = depset(
            direct = [
                "{} {}".format(
                    header.path,
                    str(target.label),
                )
                for header in (
                    compilation_context.direct_headers +
                    compilation_context.direct_textual_headers
                )
            ],
            transitive = [_dep_header_owners(ctx)],
        ),
    )

def _fix_target(target, ctx, header_owners):
    output_groups = target[OutputGroupInfo]
    if not hasattr(output_groups, "dwyu_report"):
        return []

    header_owners_file = ctx.actions.declare_file(
        "{}_dwyu_fix_header_owners.txt".format(target.label.name),
    )
    header_owners_args = ctx.actions.args()
    header_owners_args.set_param_file_format("multiline")
    header_owners_args.add_all(header_owners)
    ctx.actions.write(header_owners_file, header_owners_args)

    report_file = output_groups.dwyu_report.to_list()[0]
    status_file = output_groups.dwyu_status.to_list()[0]
    marker_file = ctx.actions.declare_file(
        "{}_dwyu_fix.marker".format(target.label.name),
    )
    ctx.actions.run_shell(
        tools = [ctx.attr._fix_deps[DefaultInfo].files_to_run],
        inputs = [report_file, status_file, header_owners_file] + getattr(ctx.files, "_cache_bust", []),
        outputs = [marker_file],
        command = """
set -euo pipefail

: > "{marker}"

# DWYU analysis without findings
if (($(<"{status}") == 0)); then
  exit 0
fi

"{tool}" "{report}" "{header_owners}"
        """.format(
            header_owners = header_owners_file.path,
            marker = marker_file.path,
            report = report_file.path,
            status = status_file.path,
            tool = ctx.executable._fix_deps.path,
        ),
        mnemonic = "DwyuFix",
        progress_message = "Fixing dependencies of %{label}",
        # The action edits BUILD files in the source tree. Running it locally
        # disables the sandbox.
        # https://bazel.build/reference/be/common-definitions#common.tags
        #
        # Note that this aspect *must* still be called with
        # `--use_action_cache=false`
        # if cache_bust isn't set
        # https://github.com/bazelbuild/bazel/issues/15516
        # https://github.com/bazelbuild/bazel/issues/21587
        execution_requirements = {"local": "1"},
    )
    return [marker_file]

def _output_group_info(target, ctx, header_owners):
    return OutputGroupInfo(
        dwyu_fix = depset(_fix_target(target, ctx, header_owners)),
    )

def _dwyu_fix_aspect_impl(target, ctx):
    if target.label.repo_name:  # is external
        marker_file = ctx.actions.declare_file(
            "{}_dwyu_fix.marker".format(target.label.name),
        )
        ctx.actions.run_shell(
            outputs = [marker_file],
            command = """
printf 'ERROR: DWYU fixes cannot be applied to external target %s\\n' '{label}' >&2
exit 1
            """.format(label = target.label),
            mnemonic = "DwyuFixError",
            progress_message = "Fixing dependencies of %{label}",
        )
        return [OutputGroupInfo(dwyu_fix = depset([marker_file]))]

    header_owner_info = _header_owner_info(target, ctx)
    return [
        header_owner_info,
        _output_group_info(target, ctx, header_owner_info.header_owners),
    ]

def dwyu_fix_aspect_factory(
        *,
        dwyu_aspect,
        # this example ignores `implementation_deps` by default
        deps_attrs = ["deps"],
        # see
        # https://chromium-review.googlesource.com/c/chromiumos/bazel/+/5420211
        # for an example of how you would define this
        cache_bust = None):
    attrs = {
        "_deps_attrs": attr.string_list(
            default = deps_attrs,
        ),
        "_fix_deps": attr.label(
            default = Label("//dwyu_fix:fix_deps"),
            executable = True,
            cfg = "exec",
        ),
    }
    if cache_bust:
        attrs["_cache_bust"] = attr.label(
            default = cache_bust,
            allow_files = True,
        )

    return aspect(
        implementation = _dwyu_fix_aspect_impl,
        attr_aspects = deps_attrs,
        required_providers = [CcInfo],
        requires = [dwyu_aspect],
        attrs = attrs,
    )
