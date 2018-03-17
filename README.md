# BOINC client for Android Development Environment

This docker container can be used to build the boinc client for android.

It is possible to selected the branch of the boinc project to be used and compiled at container creation as well as the target architecture.  Build Tools are compiled on first ssh login triggered in bashrc.  Scripts are included to build everything.  Currently there is no emulator for testing.

## Instructions to Run

The following is the most basic way to run.  Assuming the host system is 64 bit and the targets desired is arm.

1) Build or pull this image.  If building: docker build -t=geneerik/boinc-apk-builder $(pwd)
2) Create the container: docker run -d --name geneerik-boinc-apk-builder geneerik/boinc-apk-builder
3) Execute a bash shell on the container; this will trigger cloning of source repo and building of build tools.  This will only happen on the first log in of ANY user.  Command: docker exec -it geneerik-boinc-apk-builder bash
4) Once build is complete, you will be presented with a bash shell.  Kick off building of boinc with the following command: buildboinc.sh

Thats it.  Happy hacking!  Enjoy!

Note: It may be desired to use a different branch or tag of the boinc source files, openssl, or curl.  To do so, add to the paramater (without quotes) "-e BOINC_BRANCH=client_release/7/7.10" or some other branch or tag, with this example using the client_release/7/7.10 branch.  To switch architecture, the ANDROID_ARCH environmental variable can be used in the container run command like "-e ANDROID_ARCH=x86".  not all supported architectures currently have a build_wrapper script to make the andoird package.  There are other options as well for configuration in a similar manner.  These will be added to documentation in a future release, but for now can be found by looking at the dockerfile.
