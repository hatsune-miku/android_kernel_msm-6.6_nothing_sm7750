# SPDX-License-Identifier: GPL-2.0
#
# Reconstruction of the `@nt_project` repository that Nothing's kernel release
# references but did not publish.
#
# sun.bzl, msm_kernel_la.bzl and msm_kernel_16k_la.bzl all do:
#
#     load("@nt_project//:dict.bzl", "TARGET_PRODUCT")
#
# and the loaded symbol is used in exactly two ways:
#
#   1. string comparison against a project name, to append project-specific
#      in-tree modules -- sun.bzl:345 (`== "Metroid"`), sun.bzl:360
#      (`== "FroggerPro"`);
#   2. to name a build config fragment -- msm_kernel_la.bzl:117 and
#      msm_kernel_16k_la.bzl:115 do
#      `"build.config.nothing.{}".format(TARGET_PRODUCT)`.
#
# Both `build.config.nothing.FroggerPro` and `build.config.nothing.Metroid`
# are present in the tree, so the contract is fully determined: the repository
# only has to export one string constant.
#
# The value defaults to FroggerPro (Phone (4a) Pro, the target of this branch)
# and can be overridden from the environment:
#
#     TARGET_PRODUCT=Metroid tools/bazel build //msm-kernel:sun_perf_dist

_VALID_PRODUCTS = ["FroggerPro", "Metroid"]

def _nt_project_repo_impl(repository_ctx):
    target_product = repository_ctx.os.environ.get(
        "TARGET_PRODUCT",
        repository_ctx.attr.default_product,
    )

    if target_product not in _VALID_PRODUCTS:
        fail("TARGET_PRODUCT=%s is not a known Nothing project; expected one of %s. (Add build.config.nothing.%s and a matching arch/arm64/configs/vendor/%s.config if this is a new project.)" % (
            target_product,
            _VALID_PRODUCTS,
            target_product,
            target_product,
        ))

    repository_ctx.file("BUILD.bazel", "", executable = False)
    repository_ctx.file(
        "dict.bzl",
        'TARGET_PRODUCT = "{}"\n'.format(target_product),
        executable = False,
    )

nt_project_repository = repository_rule(
    implementation = _nt_project_repo_impl,
    attrs = {
        "default_product": attr.string(
            default = "FroggerPro",
            doc = "Nothing project name to use when $TARGET_PRODUCT is unset.",
        ),
    },
    environ = ["TARGET_PRODUCT"],
    doc = "Provides @nt_project//:dict.bzl with the TARGET_PRODUCT constant.",
)
