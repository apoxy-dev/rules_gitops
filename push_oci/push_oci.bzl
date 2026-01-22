"""
Implementation of the `k8s_push` rule based on rules_oci
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")

# buildifier: disable=bzl-visibility
load("@rules_oci//oci/private:util.bzl", "util")
load("//gitops:provider.bzl", "GitopsPushInfo")
load("//skylib:runfile.bzl", "get_runfile_path")

def _quote_args(args):
    return ["\"{}\"".format(arg) for arg in args]

def _impl(ctx):
    if GitopsPushInfo in ctx.attr.image:
        # the image was already pushed, just rename if needed. Ignore registry and repository parameters
        kpi = ctx.attr.image[GitopsPushInfo]
        if ctx.attr.image[DefaultInfo].files_to_run.executable:
            ctx.actions.expand_template(
                template = ctx.file._tag_tpl,
                substitutions = {
                    "%{args}": "",
                    "%{container_pusher}": get_runfile_path(ctx, ctx.attr.image[DefaultInfo].files_to_run.executable),
                },
                output = ctx.outputs.executable,
                is_executable = True,
            )
        else:
            ctx.actions.write(
                content = "#!/bin/bash\n",
                output = ctx.outputs.executable,
                is_executable = True,
            )

        runfiles = ctx.runfiles(files = []).merge(ctx.attr.image[DefaultInfo].default_runfiles)

        digest = ctx.actions.declare_file(ctx.attr.name + ".digest")
        ctx.actions.run_shell(
            tools = [kpi.digestfile],
            outputs = [digest],
            command = "cp -f \"$1\" \"$2\"",
            arguments = [kpi.digestfile.path, digest.path],
            mnemonic = "CopyFile",
            use_default_shell_env = True,
            execution_requirements = {
                "no-remote": "1",
                "no-remote-cache": "1",
                "no-remote-exec": "1",
                "no-cache": "1",
                "no-sandbox": "1",
                "local": "1",
            },
        )

        return [
            # we need to provide executable that calls the actual pusher
            DefaultInfo(
                executable = ctx.outputs.executable,
                runfiles = runfiles,
            ),
            GitopsPushInfo(
                image_label = kpi.image_label,
                repository = kpi.repository,
                digestfile = digest,
            ),
        ]

    # Get toolchain providers - no transition so single targets, not lists
    crane = ctx.attr._crane[platform_common.ToolchainInfo]
    jq = ctx.attr._jq[platform_common.ToolchainInfo]

    if ctx.attr.repository and ctx.attr.repository_file:
        fail("must specify exactly one of 'repository_file' or 'repository'")

    if not ctx.file.image.is_directory:
        fail("image attribute must be a oci_image or oci_image_index")

    _, _, _, maybe_digest, maybe_tag = util.parse_image(ctx.attr.repository)
    if maybe_digest or maybe_tag:
        fail("`repository` attribute should not contain digest or tag. got: {}".format(ctx.attr.repository))

    executable = ctx.actions.declare_file("push_%s.sh" % ctx.label.name)
    files = [ctx.file.image]
    substitutions = {
        "{{crane_path}}": crane.crane_info.binary.short_path,
        "{{jq_path}}": jq.jqinfo.bin.short_path,
        "{{image_dir}}": ctx.file.image.short_path,
        "{{fixed_args}}": "",
    }

    if ctx.attr.repository:
        substitutions["{{fixed_args}}"] += " ".join(_quote_args(["--repository", ctx.attr.repository]))
    elif ctx.attr.repository_file:
        files.append(ctx.file.repository_file)
        substitutions["{{repository_file}}"] = ctx.file.repository_file.short_path
    else:
        fail("must specify exactly one of 'repository_file' or 'repository'")

    if ctx.attr.remote_tags:
        files.append(ctx.file.remote_tags)
        substitutions["{{tags}}"] = ctx.file.remote_tags.short_path

    ctx.actions.expand_template(
        template = ctx.file._push_sh_tpl,
        output = executable,
        is_executable = True,
        substitutions = substitutions,
    )
    runfiles = ctx.runfiles(files = files)
    runfiles = runfiles.merge(jq.default.default_runfiles)
    runfiles = runfiles.merge(ctx.attr.image[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(crane.default.default_runfiles)

    default_info = DefaultInfo(executable = util.maybe_wrap_launcher_for_windows(ctx, executable), runfiles = runfiles)

    # Extract digest for GitopsPushInfo
    jq_bin = ctx.toolchains["@aspect_bazel_lib//lib:jq_toolchain_type"].jqinfo.bin
    digest = ctx.actions.declare_file(ctx.attr.name + ".digest")
    ctx.actions.run_shell(
        inputs = [ctx.file.image],
        outputs = [digest],
        arguments = [jq_bin.path, ctx.file.image.path, digest.path],
        command = "${1} --raw-output '.manifests[].digest' ${2}/index.json > ${3}",
        progress_message = "Extracting digest from %s" % ctx.file.image.short_path,
        tools = [jq_bin],
    )

    return [
        default_info,
        GitopsPushInfo(
            image_label = ctx.attr.image.label,
            repository = ctx.attr.repository,
            digestfile = digest,
        ),
    ]

# Override _crane and _jq to use host platform instead of target platform.
# This fixes "Exec format error" when running push scripts locally with
# cross-platform builds (e.g., building linux_amd64 on darwin_arm64).
# The original rules_oci attrs use cfg=_transition_to_target which forces
# execution platform to match target platform.
_push_oci_attrs = {
    "image": attr.label(
        allow_single_file = True,
        doc = "Label to an oci_image or oci_image_index",
        mandatory = True,
    ),
    "repository": attr.string(
        doc = "Repository URL where the image will be signed at, e.g.: `index.docker.io/<user>/image`. Digests and tags are not allowed.",
    ),
    "repository_file": attr.label(
        doc = "The same as 'repository' but in a file. This allows pushing to different repositories based on stamping.",
        allow_single_file = True,
    ),
    "remote_tags": attr.label(
        doc = "a text file containing tags, one per line.",
        allow_single_file = True,
    ),
    "_crane": attr.label(
        default = "@oci_crane_toolchains//:current_toolchain",
    ),
    "_jq": attr.label(
        default = "@jq_toolchains//:resolved_toolchain",
    ),
    "_push_sh_tpl": attr.label(
        default = "@rules_oci//oci/private:push.sh.tpl",
        allow_single_file = True,
    ),
    "_tag_tpl": attr.label(
        default = Label("//push_oci:tag.sh.tpl"),
        allow_single_file = True,
    ),
    "_windows_constraint": attr.label(default = "@platforms//os:windows"),
}

push_oci_rule = rule(
    implementation = _impl,
    attrs = _push_oci_attrs,
    toolchains = [
        "@aspect_bazel_lib//lib:jq_toolchain_type",
        "@bazel_tools//tools/sh:toolchain_type",
    ],
    executable = True,
)

def push_oci(
        name,
        image,
        repository,
        registry = None,
        image_digest_tag = False,  # buildifier: disable=unused-variable either remove parameter or implement
        tag = None,
        remote_tags = None,  # file with tags to push
        tags = [],  # bazel tags to add to the push_oci_rule
        visibility = None):
    if tag:
        tags_label = "_{}_write_tags".format(name)
        write_file(
            name = tags_label,
            out = "_{}.tags.txt".format(name),
            content = remote_tags,
        )
        remote_tags = tags_label

    if not repository:
        label = native.package_relative_label(image)
        repository = "{}/{}".format(label.package, label.name)
    if registry:
        repository = "{}/{}".format(registry, repository)
    push_oci_rule(
        name = name,
        image = image,
        repository = repository,
        remote_tags = remote_tags,
        tags = tags,
        visibility = visibility,
    )
