---
layout: layout.njk
title: Containers and Compose
---
# Containers and Docker Compose

The **Containers** menu is for individual Docker containers. The **Compose** view is reached from **Deploy Compose** and manages named multi-container projects.

## Create and operate a container

Select **Create container**. The form accepts a container name and Docker image, plus optional hostname, restart policy, CPU and memory limits, network, user, working directory, entrypoint, read-only root filesystem, environment variables, published ports, volumes, labels, and command arguments. The command preview at the bottom is a useful final check of the Docker invocation before you select **Create container**.

Use Docker-style values: `8080:80` publishes host port 8080 to container port 80; `NAME=value` is an environment variable; `volume-name:/data` mounts a named volume. Enter one command argument per line. Do not use shell quoting to group them: each line is passed as its own argument.

Choose **Start at host boot** when the service should return after a host reboot; it uses Docker's `unless-stopped` policy. A normal restart policy is selected separately when this switch is off. **Read-only root filesystem** prevents writes to the image's writable layer; pair it with explicit writable volumes or tmpfs paths where the image requires them.

| Button | What it does |
| --- | --- |
| **Start**, **Stop**, **Restart** | Performs the corresponding Docker lifecycle action. Stop asks Docker to end the container; restart interrupts its current process. |
| **Inspect** / **Details** | Shows Docker metadata and exposes resource editing where supported. It is diagnostic; it does not change the container by itself. |
| **Logs** | Opens the container output viewer. **Refresh** fetches the current output and **Stop** stops the log-follow request, not the container. |
| **Terminal** | Opens a short-lived terminal session inside the container. `/bin/sh` is the normal shell, but it must exist in the image. |
| **Snapshot** | Commits the current writable container filesystem to a Docker image tag. Leave “pause while committing” enabled unless you have a reason not to. This is not a volume backup. |
| **Delete** | Force-removes the container. It does not automatically remove named volumes or its image. |

Inside **Inspect**, the live CPU, memory, writable-layer, and network panel refreshes every five seconds. The resource form can change **CPUs**, **Memory**, and **Restart policy**. The summary repeats the image, status, restart policy, and network mode; the lower **Docker inspect** panel is the raw Docker metadata for diagnosis. The **Logs**, **Snapshot**, and (when running) **Terminal** buttons in that dialog do the same things as the row buttons.

An image is only the container filesystem template; it is not a backup of external named volumes, bind mounts, or data stored elsewhere. Use **Volumes** or host backup practices for persistent data.

## Deploy a Compose project

Select **Deploy Compose** on the Containers page. Enter a stable **project name**, then paste Compose YAML or choose a `.yaml`/`.yml` file. TinyVisor validates it before deployment. The project name groups the services and is the name you return to for later operations.

After a project exists, its controls mean:

| Button | What it does |
| --- | --- |
| **View** | Displays the YAML stored for that project. |
| **Deploy** | Applies the saved YAML again, creating or reconciling its services. |
| **Down** | Stops the Compose stack. Use it before planned changes or removal. |
| **Delete** | Stops the stack and removes TinyVisor's stored project file. Review the confirmation carefully. |

Compose YAML can publish host ports, mount host paths, create networks, and choose restart policies. Treat it as infrastructure configuration: review it before deployment and keep the source YAML in version control as well as in the console.
