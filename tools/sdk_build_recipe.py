"""Actual Linux SDK build invocation, independent of artifact transport."""


def docker_build_command(component, image, parent_images, root):
    recipe = (
        "packaging/sdk.Dockerfile"
        if component == "linux-sdk"
        else f"packaging/sdk-{component.removeprefix('linux-')}.Dockerfile"
    )
    command = ["docker", "build", "-f", str(root / recipe), "-t", image]
    for parent, parent_image in parent_images.items():
        argument = parent.removeprefix("linux-").upper() + "_IMAGE"
        command += ["--build-arg", f"{argument}={parent_image}"]
    return [*command, str(root)]
