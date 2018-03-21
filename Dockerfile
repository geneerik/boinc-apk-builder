#
# boinc Builder docker container
#
# Docker file to start an Ubuntu docker instance with tools necessary for building
# boinc for android and its app
#
# Build it like so:
#   root@host~# docker build -t=geneerik/boinc-apk-builder $(pwd)
#
# Launch the generated image like so:
#
#   docker run -d --name geneerik-boinc-apk-builder geneerik/boinc-apk-builder
#
# Connect like so:
#
#   $ docker exec -it geneerik-boinc-apk-builder bash
#
# build with buildboincapkall.sh command
#
# Gene Erik
# --

#
#  From this base-image / starting-point

FROM ubuntu:xenial

ENV BOINC_BRANCH ${BOINC_BRANCH:-master}
#Was 1.0.2k but distclean not introduced until newer build
ENV OPENSSL_VERSION ${OPENSSL_VERSION:-1.0.2n}
#This was originally 7.53.1, but the version needs to be bumped for distclean to work
ENV CURL_VERSION ${CURL_VERSION:-7.57.0}
ENV ANDROID_ARCH ${:-arm}
ENV ANDROID_CMAKE_VERSION ${ANDROID_CMAKE_VERSION:-3.6.4111459}

#These could maybe be exported in bashrc as they are static
ENV ANDROID_HOME /opt/android-sdk
ENV ANDROID_NDK /opt/android-sdk/ndk-bundle
ENV ANDROID_NDK_HOME /opt/android-sdk/ndk-bundle
ENV NDK_ROOT /opt/android-sdk/ndk-bundle

#
#  Authorship
#
MAINTAINER geneerik@thisdomaindoesntexistyet.com

#Install prerequisites for getting boinc
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade  --yes --force-yes && \
	DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends \
		ca-certificates curl wget gnupg dirmngr git openssh-client procps \
		expect --yes --force-yes
		
#Get build tools
RUN DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends \
		build-essential gcc-5 nasm automake libtool python pkg-config cpio --yes --force-yes

#TODO: {openGL, GLU, glut} dev libraries???
#http://boinc.berkeley.edu/trac/wiki/SoftwarePrereqsUnix
#freeglut3-dev?
#https://build.opensuse.org/package/view_file/network/boinc-client/boinc-client.spec?expand=1
		
#Interesting...
#https://github.com/matszpk/native-boinc-for-android/blob/master/src/milkyway_separation_0.88/INSTALL
		
#create source destination directory
RUN mkdir /opt/src && chmod 777 /opt/src

### JAVA stuff

# A few reasons for installing distribution-provided OpenJDK:
#
#  1. Oracle.  Licensing prevents us from redistributing the official JDK.
#
#  2. Compiling OpenJDK also requires the JDK to be installed, and it gets
#     really hairy.
#
#     For some sample build times, see Debian's buildd logs:
#       https://buildd.debian.org/status/logs.php?pkg=openjdk-8

RUN DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends \
		bzip2 unzip xz-utils locales --yes --force-yes

# Default to UTF-8 file.encoding
RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8

ENV LANG en_US.UTF-8 

# add a simple script that can auto-detect the appropriate JAVA_HOME value
# based on whether the JDK or only the JRE is installed
RUN { \
		echo '#!/bin/sh'; \
		echo 'set -euf'; \
		echo; \
		echo 'dirname "$(dirname "$(readlink -f "$(which javac || which java)")")"'; \
	} > /usr/local/bin/docker-java-home \
	&& chmod +x /usr/local/bin/docker-java-home

# do some fancy footwork to create a JAVA_HOME that's cross-architecture-safe
RUN ln -svT "/usr/lib/jvm/java-8-openjdk-$(dpkg --print-architecture)" /docker-java-home
ENV JAVA_HOME /docker-java-home

ENV JAVA_DEBIAN_VERSION ${JAVA_DEBIAN_VERSION:-8u151-b12-0ubuntu0.16.04.2}
#This should probably be done dynamically and put in bashrc; TODO
ENV JAVA_VERSION 1.8.0_151

RUN set -ex; \
	\
# deal with slim variants not having man page directories (which causes "update-alternatives" to fail)
	if [ ! -d /usr/share/man/man1 ]; then \
		mkdir -p /usr/share/man/man1; \
	fi; \
	\
	DEBIAN_FRONTEND=noninteractive apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install openjdk-8-jdk="$JAVA_DEBIAN_VERSION" --yes --force-yes\
	; \
	\
# verify that "docker-java-home" returns what we expect
	[ "$(readlink -f "$JAVA_HOME")" = "$(docker-java-home)" ]; \
	\
# update-alternatives so that future installs of other OpenJDK versions don't change /usr/bin/java
	update-alternatives --get-selections | awk -v home="$(readlink -f "$JAVA_HOME")" 'index($3, home) == 1 { $2 = "manual"; print | "update-alternatives --set-selections" }'; \
# ... and verify that it actually worked for one of the alternatives we care about
	update-alternatives --query java | grep -q 'Status: manual'

#patches included based off of commit 20b634b0fd8be1d1b1702c054f59ac105a53982f (3/18/2018)
	
#Make the boinc patches directory 
RUN mkdir -p /boinc_patches

#Create patch for broken hostinfo_unix.cpp file
RUN ( echo 'diff --git a/client/hostinfo_unix.cpp b/client/hostinfo_unix.cpp' > /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo 'index 7107a83..e0c97a9 100644' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '--- a/client/hostinfo_unix.cpp' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '+++ b/client/hostinfo_unix.cpp' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '@@ -74,11 +74,11 @@' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #include <sys/stat.h>' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' ' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #if HAVE_SYS_SWAP_H' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '-#if defined(ANDROID) && !defined(ANDROID_64)' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '-#include <linux/swap.h>' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '-#else' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #include <sys/swap.h>' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #endif' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '+' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '+#if HAVE_SYS_WAIT_H' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo '+#include <sys/wait.h>' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #endif' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' ' >> /boinc_patches/boinc_hostinfo.cpp.patch ) && \
	( echo ' #if HAVE_SYS_SYSCTL_H' >> /boinc_patches/boinc_hostinfo.cpp.patch )

#TODO: add sed safety checks
	
#patch to set API version and eliminate buildToolsVersion
#from /opt/src/boinc/android/BOINC/app/build.gradle
ENV MIN_ANDROID_API_VERSION ${MIN_ANDROID_API_VERSION:-16}
ENV APK_COMPILE_API_VERSION ${APK_COMPILE_API_VERSION:-23}
ENV APK_TARGET_API_VERSION ${APK_TARGET_API_VERSION:-23}

#TODO: the regex matches here for sed are pretty lame and dangerous; this should be made safer
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/patch_build_gradle.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/patch_build_gradle.sh ) && \
	( echo 'sed -i -e "s@^.*compileSdkVersion\\s*\\(\\d*\\).*@compileSdkVersion ${APK_COMPILE_API_VERSION}@" /opt/src/boinc/android/BOINC/app/build.gradle' >> /usr/local/bin/patch_build_gradle.sh ) && \
	( echo 'sed -i -e "s@^.*buildToolsVersion\\s*\\"\\(.*\\)\\".*@@" /opt/src/boinc/android/BOINC/app/build.gradle' >> /usr/local/bin/patch_build_gradle.sh ) && \
	( echo 'sed -i -e "s@^.*minSdkVersion\\s*\\(\\d*\\).*@        minSdkVersion ${MIN_ANDROID_API_VERSION}@" /opt/src/boinc/android/BOINC/app/build.gradle' >> /usr/local/bin/patch_build_gradle.sh ) && \
	( echo 'sed -i -e "s@^.*targetSdkVersion\\s*\\(\\d*\\).*@        targetSdkVersion ${APK_TARGET_API_VERSION}@" /opt/src/boinc/android/BOINC/app/build.gradle' >> /usr/local/bin/patch_build_gradle.sh ) && \
	chmod +x /usr/local/bin/patch_build_gradle.sh

#Original version was 2.14.1, but that is too low for
#automatic build tools selection (4.1 or higher needed)
ENV GRADLE_VERSION ${GRADLE_VERSION:-4.1}
#patch to change gradle version in /opt/src/boinc/android/BOINC/gradle/wrapper/gradle-wrapper.properties
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/patch_gradle_wrapper.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/patch_gradle_wrapper.sh ) && \
	( echo 'sed -i -e "s@^distributionUrl=.*@distributionUrl=https\://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-all.zip@" /opt/src/boinc/android/BOINC/gradle/wrapper/gradle-wrapper.properties' >> /usr/local/bin/patch_gradle_wrapper.sh ) && \
	chmod +x /usr/local/bin/patch_gradle_wrapper.sh
	
#Create script to clone the boinc repo
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getboinc.sh' ) && \
	( echo 'set -eu -o pipefail' >> /usr/local/bin/getboinc.sh ) && \
	( echo 'mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/BOINC/boinc.git && \
	cd boinc && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git pull --tags && \
	git checkout ${BOINC_BRANCH} && \
	git pull --all && \
	git apply /boinc_patches/*.patch && \
	rm -rf /opt/src/boinc/android/BOINC/app/src/main/res/values-az/ && \
	rm -rf /opt/src/boinc/android/BOINC/app/src/main/res/values-sr\@latin && \
	patch_gradle_wrapper.sh && \
	patch_build_gradle.sh && \
	patch_build_script_safety.sh' >> /usr/local/bin/getboinc.sh ) && \
	chmod +x /usr/local/bin/getboinc.sh

##Note: If the build tools for the target platform (API) 
##are needed, they can be retrieved with:
#cd /opt/src/boinc/android/BOINC/
#./gradlew tasks
##Note: these should only be needed when building the APK
##and are downloaded automatically
	
#P TODO: bring this to a working start with ndk 16
#0 is a magic version number that will make the script use
#sdkmanager get the latest NDK rather than downloading a specific one
ENV ANDROID_NDK_VERSION ${ANDROID_NDK_VERSION:-r15c}
	
#Create script to get android ndk and sdk and create build tool chain
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getandtools.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/getandtools.sh ) && \
    ( echo 'export COMPILE_SDK=`sed -n "s/.*minSdkVersion\\s*\\(\\d*\\)/\\1/p" /opt/src/boinc/android/BOINC/app/build.gradle`' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export ANDROID_TC="${ANDROID_HOME}/Toolchains"' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export ANDROID_LIBPATH="${ANDROID_TC}/${ANDROID_ARCH}/sysroot/usr/lib/"' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export OPENSSL_SRC=/opt/src/openssl-${OPENSSL_VERSION}' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export CURL_SRC=/opt/src/curl-${CURL_VERSION}' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'if [[ ! -e ${ANDROID_HOME} ]]; then' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	wget -q --output-document=/tmp/sdk-tools.zip https://dl.google.com/android/repository/sdk-tools-linux-3859397.zip && \' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	unzip -d ${ANDROID_HOME} /tmp/sdk-tools.zip' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	rm -f /tmp/sdk-tools.zip' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	mkdir -p /root/.android' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	touch /root/.android/repositories.cfg' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	acceptandroidsdklics.sh' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	${ANDROID_HOME}/tools/bin/sdkmanager --update' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	if [[ "${ANDROID_NDK_VERSION}" == "0" ]]; then' >> /usr/local/bin/getandtools.sh ) && \
	( echo '		${ANDROID_HOME}/tools/bin/sdkmanager "ndk-bundle"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	else' >> /usr/local/bin/getandtools.sh ) && \
	( echo '		set +f' >> /usr/local/bin/getandtools.sh ) && \
	( echo '		wget -O /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux-x86_64.zip && unzip -d ${ANDROID_HOME} /tmp/ndk.zip && mv ${ANDROID_HOME}/android-ndk-${ANDROID_NDK_VERSION} ${ANDROID_NDK_HOME}' >> /usr/local/bin/getandtools.sh ) && \
	( echo '		set -f' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	fi' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	${ANDROID_HOME}/tools/bin/sdkmanager "platforms;android-${COMPILE_SDK}"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	${ANDROID_HOME}/tools/bin/sdkmanager "extras;android;m2repository" "extras;google;m2repository" "extras;google;google_play_services"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	${ANDROID_HOME}/tools/bin/sdkmanager "cmake;${ANDROID_CMAKE_VERSION}"' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'fi' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'if [[ ! -e ${OPENSSL_SRC} ]]; then' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	# OpenSSL sources' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	wget -O /tmp/openssl.tgz https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz' >> /usr/local/bin/getandtools.sh ) && \
    ( echo '	tar xzf /tmp/openssl.tgz --directory=/opt/src' >> /usr/local/bin/getandtools.sh ) && \
    ( echo 'fi' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'if [[ ! -e ${CURL_SRC} ]]; then' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	# cURL sources' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	wget -O /tmp/curl.tgz https://curl.haxx.se/download/curl-${CURL_VERSION}.tar.gz' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	tar xzf /tmp/curl.tgz --directory=/opt/src' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	rm ${CURL_SRC}/Makefile' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'fi' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export PATH=${PATH}:${ANDROID_HOME}/tools/bin:${ANDROID_HOME}/platform-tools:${PATH}:${ANDROID_HOME}/tools' >> /usr/local/bin/getandtools.sh ) && \
	chmod +x /usr/local/bin/getandtools.sh
#Note: the above removes the original makefile; this will be replaced when the first ./configure is done and does not contain distclean
	
# Add git clone to bashrc for root
RUN cp -r /etc/skel/. /root && \
	( echo "if [[ ! -e /opt/src/boinc ]];then /usr/local/bin/getboinc.sh; fi" >> /root/.bashrc ) && \
	( echo ". usr/local/bin/getandtools.sh" >> /root/.bashrc ) && \
	chmod +x /root/.bashrc

#Update sdk script
RUN ( bash -c 'echo -e "#!/usr/bin/expect -d\n\n" > /usr/local/bin/acceptandroidsdklics.sh' ) && \
	( echo 'set timeout -1' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo 'exp_internal 1' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo 'set cmd "$env(ANDROID_HOME)/tools/bin/sdkmanager --update"' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo; >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo 'spawn {*}$cmd' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo 'expect {' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	"Review licenses that have not been accepted*" {' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		send_user "Caught review; sending yes"' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		exp_send "y\\r"' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		exp_continue' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	}' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	"Accept?*" {' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		send_user "Caught accept; sending yes\n"' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		exp_send "y\\r"' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '		exp_continue' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	}' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	timeout {puts "expect script timed out"}' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '	eof     {puts "exitted due to EOF"}' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	( echo '}' >> /usr/local/bin/acceptandroidsdklics.sh ) && \
	chmod +x /usr/local/bin/acceptandroidsdklics.sh

# script to build all targets: arm64 arm mips mips64 x86_64 x86
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/buildboincforalltargets.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo 'targetArchList=( "arm" "arm64" "x86_64" "x86" "mips" "mips64" )' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo 'for curTargetArch in "${targetArchList[@]}"' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo 'do' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo '	ANDROID_ARCH=${curTargetArch} buildboinc.sh' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo 'done' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	( echo 'echo "All targets built successfully for boinc!"' >> /usr/local/bin/buildboincforalltargets.sh ) && \
	chmod +x /usr/local/bin/buildboincforalltargets.sh

# code to build apk
#WARNING: this command currently disables linting during the gradle build of the app;
#This should not be done, but is currently REQUIRED because the source code
#structure violates some rules
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/buildboincapkonly.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/buildboincapkonly.sh ) && \
	( echo 'cd /opt/src/boinc/android/BOINC' >> /usr/local/bin/buildboincapkonly.sh ) && \
	( echo './gradlew ${BOINC_APK_BUILD_TASK} -x lint 2>&1 | tee ../build_apk_arm.log' >> /usr/local/bin/buildboincapkonly.sh ) && \
	( echo 'cp -a /opt/src/boinc/android/BOINC/app/build/outputs/apk /opt/boinc_build/' >> /usr/local/bin/buildboincapkonly.sh ) && \
	( echo 'echo "Successfully built apk for boinc!"' >> /usr/local/bin/buildboincapkonly.sh ) && \
	chmod +x /usr/local/bin/buildboincapkonly.sh

#The other build tasks should do something like this
#eg. for TRANSLATED_ANDROID_ARCH: when ANDROID_ARCH is arm TRANSLATED_ANDROID_ARCH is armeabi-v7a
#cp /opt/boinc_build/${ANDROID_ARCH}/stage/usr/local/bin/{boinc,boinccmd} /opt/src/boinc/android/BOINC/app/src/main/assets/${TRANSLATED_ANDROID_ARCH}/
#rm /opt/src/boinc/android/BOINC/app/src/main/assets/${TRANSLATED_ANDROID_ARCH}/placeholder.txt

# code to build all targets then apk; this is the master scipt!
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/buildboincapkall.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/buildboincapkall.sh ) && \
	( echo 'buildboincforalltargets.sh && buildboincapkonly.sh' >> /usr/local/bin/buildboincapkall.sh ) && \
	( echo 'echo "Successfully built all targets and loaded apk for boinc!"' >> /usr/local/bin/buildboincapkall.sh ) && \
	( echo 'echo "Today is a great day for science"' >> /usr/local/bin/buildboincapkall.sh ) && \
	chmod +x /usr/local/bin/buildboincapkall.sh

ENV BOINC_APK_BUILD_TASK ${BOINC_APK_BUILD_TASK:-build}

# patch for gradle plugin v 3.0.1 so specifying build tools is no longer required
RUN ( echo 'diff --git a/android/BOINC/build.gradle b/android/BOINC/build.gradle' > /boinc_patches/apk_build_gradle.patch ) && \
	( echo 'index e7e3c60..0f78b49 100644' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '--- a/android/BOINC/build.gradle' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '+++ b/android/BOINC/build.gradle' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '@@ -2,9 +2,10 @@' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo ' buildscript {' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '     repositories {' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '         jcenter()' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '+        google()' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '     }' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '     dependencies {' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo "-        classpath 'com.android.tools.build:gradle:2.2.2'" >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo "+        classpath 'com.android.tools.build:gradle:3.0.1'" >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '     }' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo ' }' >> /boinc_patches/apk_build_gradle.patch ) && \
	( echo '' >> /boinc_patches/apk_build_gradle.patch )

#TODO: patch build boinc libs and wrapper with -D__ANDROID_API__=${COMPILE_SDK}
ENV ANDROID_TC_ARGS ${ANDROID_TC_ARGS:---deprecated-headers}

ENV TOOL_TO_BUILD_TC ${TOOL_TO_BUILD_TC:-py}

#Create boinc build script
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/buildboinc.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'export COMPILE_SDK=`sed -n "s/.*minSdkVersion\\s*\\(\\d*\\)/\\1/p" /opt/src/boinc/android/BOINC/app/build.gradle`' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ ${ANDROID_ARCH:(-2)} == "64" && ${COMPILE_SDK} -lt 21 ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	echo "WARNING: target sdk version for compile ${COMPILE_SDK} is lower than the required SDK version for 64 bit targets, which ${ANDROID_ARCH} is.  The compile sdk will be bumped up to 21 for the binary compiles with the stand alone tool chain"' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	export COMPILE_SDK=21' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ ! -e ${ANDROID_HOME}/platforms/android-${COMPILE_SDK} ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	${ANDROID_HOME}/tools/bin/sdkmanager "platforms;android-${COMPILE_SDK}"' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '#if [[ ! -e ${ANDROID_TC}/${ANDROID_ARCH} ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	if [[ ${TOOL_TO_BUILD_TC} == "sh" ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '		${ANDROID_NDK_HOME}/build/tools/make-standalone-toolchain.sh --arch=${ANDROID_ARCH} --platform=android-${COMPILE_SDK} --install-dir=${ANDROID_TC}/${ANDROID_ARCH} ${ANDROID_TC_ARGS} --force' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	else' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '		${ANDROID_NDK_HOME}/build/tools/make_standalone_toolchain.py --arch ${ANDROID_ARCH} --api ${COMPILE_SDK} --install-dir ${ANDROID_TC}/${ANDROID_ARCH} ${ANDROID_TC_ARGS} --force' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '#fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'cd /opt/src/boinc/android' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_androidtc_${ANDROID_ARCH}.sh 2>&1 | tee build_androidtc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'assert_no_fatal.sh build_androidtc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ "${ANDROID_ARCH}" == "arm" || "${ANDROID_ARCH}" == "mips" || "${ANDROID_ARCH}" == "x86" ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	./build_libraries_${ANDROID_ARCH}.sh 2>&1 | tee build_libraries_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	assert_no_fatal.sh build_libraries_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_openssl_${ANDROID_ARCH}.sh 2>&1 | tee build_openssl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'assert_no_fatal.sh build_openssl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_curl_${ANDROID_ARCH}.sh 2>&1 | tee build_curl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'assert_no_fatal.sh build_curl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_boinc_${ANDROID_ARCH}.sh 2>&1 | tee build_boinc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'mkdir -p /opt/boinc_build/${ANDROID_ARCH}' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'assert_no_fatal.sh build_boinc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'cd .. && ( find stage/ -depth -print0 | cpio -pamvVd0 /opt/boinc_build/${ANDROID_ARCH} ) && cd android' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ "${ANDROID_ARCH}" == "arm" || "${ANDROID_ARCH}" == "mips" || "${ANDROID_ARCH}" == "x86" ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	./build_wrapper_${ANDROID_ARCH}.sh 2>&1 | tee build_wrapper_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	assert_no_fatal.sh build_wrapper_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	cp -a /opt/src/boinc/samples/wrapper/wrapper /opt/boinc_build/${ANDROID_ARCH}/' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'echo "successfully built boinc for android API ${COMPILE_SDK} on arch ${ANDROID_ARCH}!!"' >> /usr/local/bin/buildboinc.sh ) && \
	chmod +x /usr/local/bin/buildboinc.sh

#Patch to set -e on ALL of the build scripts so that it will die when something fails
#My patch here looks wrong but that is because the shebang notation in ALL of the build scripts is wrong
#TODO: this COULD be a patch file since its static; convert from script
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/patch_build_script_safety.sh' ) && \
	( echo 'set -eu -o pipefail' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo 'for filename in /opt/src/boinc/android/*.sh; do' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo '	if ! grep -Fq "set -euf" "${filename}"; then' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo '		echo "fixing safety for ${filename}"' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo "		sed -i -e \"s@^#/bin/sh\\\$@#!/bin/sh\\\nset -euf@\" \${filename}" >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo '	fi' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	( echo 'done' >> /usr/local/bin/patch_build_script_safety.sh ) && \
	chmod +x /usr/local/bin/patch_build_script_safety.sh

#Add script to check for build fail for each stage (look for fatals)
#This will likely need some more work; would fail if anything
#in the build uses the word fatal; this is just a simple version for now
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/assert_no_fatal.sh' ) && \
	( echo 'set -euf -o pipefail' >> /usr/local/bin/assert_no_fatal.sh ) && \
	( echo 'TARGET_FILENAME=$1' >> /usr/local/bin/assert_no_fatal.sh ) && \
	( echo 'if grep -Fxq "fatal" "${TARGET_FILENAME}"; then ' >> /usr/local/bin/assert_no_fatal.sh ) && \
	( echo '	echo "found fatal in file ${TARGET_FILENAME}; cannot continue"' >> /usr/local/bin/assert_no_fatal.sh ) && \
	( echo '	exit 99' >> /usr/local/bin/assert_no_fatal.sh ) && \
	( echo 'fi' >> /usr/local/bin/assert_no_fatal.sh ) && \
	chmod +x /usr/local/bin/assert_no_fatal.sh

#TODO: add script to sign apk

# patch to fix "clean" and low API on new ndk for openssl build scripts
RUN ( echo 'diff --git a/android/build_openssl_arm.sh b/android/build_openssl_arm.sh' > /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index 9161dd3..b71372a 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_arm.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_arm.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=arm-linux-androideabi-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=arm-linux-androideabi-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=arm-linux-androideabi-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie -march=armv7-a -Wl,--fix-cortex-a8"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-generic32 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'diff --git a/android/build_openssl_arm64.sh b/android/build_openssl_arm64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index 7a2c526..c412110 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_arm64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_arm64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=aarch64-linux-android-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=aarch64-linux-android-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=aarch64-linux-android-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-generic32 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'diff --git a/android/build_openssl_mips.sh b/android/build_openssl_mips.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index 849f489..c52d5df 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_mips.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_mips.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=mipsel-linux-android-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=mipsel-linux-android-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=mipsel-linux-android-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-generic32 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'diff --git a/android/build_openssl_mips64.sh b/android/build_openssl_mips64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index 0d2ff56..45b25a5 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_mips64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_mips64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -22,8 +22,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=mips64el-linux-android-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=mips64el-linux-android-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=mips64el-linux-android-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib64 -L$TCINCLUDES/lib64 -llog -fPIE -pie"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -33,8 +33,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-generic64 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'diff --git a/android/build_openssl_x86.sh b/android/build_openssl_x86.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index fc109db..c5f7fca 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_x86.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_x86.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=i686-linux-android-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=i686-linux-android-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=i686-linux-android-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-generic32 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'diff --git a/android/build_openssl_x86_64.sh b/android/build_openssl_x86_64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo 'index 50c2c4d..79bb5f9 100755' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '--- a/android/build_openssl_x86_64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+++ b/android/build_openssl_x86_64.sh' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CC=x86_64-linux-android-gcc' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export CXX=x86_64-linux-android-g++' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LD=x86_64-linux-android-ld' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$COMPILEOPENSSL" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' echo "================building openssl from $OPENSSL============================="' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' cd $OPENSSL' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo ' ./Configure linux-x86_64 no-shared no-dso -DL_ENDIAN --openssldir="$TCINCLUDES/ssl"' >> /boinc_patches/build_openssl_sh.patch ) && \
	( echo '' >> /boinc_patches/build_openssl_sh.patch )

# patch to fix "clean" and low API on new ndk for curl build scripts
#WARNING: In this patch, we are disabling warnings for curl build;
#this is needed as there is a warning that is thrown incorrectly with
#some ndk versions that when used in conjunction with certain cURL
#versions, results in a build failure when it should not
RUN ( echo 'diff --git a/android/build_curl_arm.sh b/android/build_curl_arm.sh' > /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index a6b04f5..0e12df2 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_arm.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_arm.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=arm-linux-androideabi-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=arm-linux-androideabi-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=arm-linux-androideabi-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16 -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie -march=armv7-a -Wl,--fix-cortex-a8"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ./configure --host=arm-linux --prefix=$TCINCLUDES --libdir="$TCINCLUDES/lib" --disable-shared --enable-static --with-random=/dev/urandom --without-zlib' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'diff --git a/android/build_curl_arm64.sh b/android/build_curl_arm64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index 02edb67..7b5f458 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_arm64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_arm64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=aarch64-linux-android-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=aarch64-linux-android-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=aarch64-linux-android-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -34,7 +34,7 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'diff --git a/android/build_curl_mips.sh b/android/build_curl_mips.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index 0990df2..0afb454 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_mips.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_mips.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=mipsel-linux-android-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=mipsel-linux-android-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=mipsel-linux-android-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ./configure --host=mipsel-linux --prefix=$TCINCLUDES --libdir="$TCINCLUDES/lib" --disable-shared --enable-static --with-random=/dev/urandom' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'diff --git a/android/build_curl_mips64.sh b/android/build_curl_mips64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index ae3cd60..499806d 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_mips64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_mips64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -22,8 +22,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=mips64el-linux-android-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=mips64el-linux-android-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=mips64el-linux-android-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib64 -L$TCINCLUDES/lib64 -llog -fPIE -pie"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -33,7 +33,7 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'diff --git a/android/build_curl_x86.sh b/android/build_curl_x86.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index 9671f5f..e10fb52 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_x86.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_x86.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=i686-linux-android-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=i686-linux-android-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=i686-linux-android-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -34,8 +34,8 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ./configure --host=i686-linux --prefix=$TCINCLUDES --libdir="$TCINCLUDES/lib" --disable-shared --enable-static --with-random=/dev/urandom' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'diff --git a/android/build_curl_x86_64.sh b/android/build_curl_x86_64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo 'index f9c7dfc..d49d93c 100755' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '--- a/android/build_curl_x86_64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+++ b/android/build_curl_x86_64.sh' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CC=x86_64-linux-android-gcc' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export CXX=x86_64-linux-android-g++' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LD=x86_64-linux-android-ld' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK} -w"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '@@ -34,7 +34,7 @@ export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$COMPILECURL" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' echo "==================building curl from $CURL================================="' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' cd $CURL' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_curl_sh.patch ) && \
	( echo '' >> /boinc_patches/build_curl_sh.patch )
	
# patch to fix "clean" and low API on new ndk for boinc build scripts
RUN ( echo 'diff --git a/android/build_boinc_arm.sh b/android/build_boinc_arm.sh' > /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index 9ebfc09..ddb5a29 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_arm.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_arm.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=arm-linux-androideabi-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=arm-linux-androideabi-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=arm-linux-androideabi-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -march=armv7-a -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -march=armv7-a -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie -march=armv7-a -Wl,--fix-cortex-a8"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' arm-linux-androideabi-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'diff --git a/android/build_boinc_arm64.sh b/android/build_boinc_arm64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index f63385e..2480608 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_arm64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_arm64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=aarch64-linux-android-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=aarch64-linux-android-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=aarch64-linux-android-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' aarch64-linux-android-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'diff --git a/android/build_boinc_mips.sh b/android/build_boinc_mips.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index 2283c4f..4aaeaf4 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_mips.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_mips.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=mipsel-linux-android-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=mipsel-linux-android-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=mipsel-linux-android-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' mipsel-linux-android-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'diff --git a/android/build_boinc_mips64.sh b/android/build_boinc_mips64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index 2a97cf6..234cc6f 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_mips64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_mips64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=mips64el-linux-android-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=mips64el-linux-android-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=mips64el-linux-android-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib64 -L$TCINCLUDES/lib64 -llog -fPIE -pie"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' mips64el-linux-android-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'diff --git a/android/build_boinc_x86.sh b/android/build_boinc_x86.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index a96e525..e299ed2 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_x86.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_x86.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=i686-linux-android-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=i686-linux-android-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=i686-linux-android-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib -L$TCINCLUDES/lib -llog -fPIE -pie"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' i686-linux-android-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'diff --git a/android/build_boinc_x86_64.sh b/android/build_boinc_x86_64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo 'index d41e50a..c64a268 100755' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '--- a/android/build_boinc_x86_64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+++ b/android/build_boinc_x86_64.sh' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -23,8 +23,8 @@ export PATH="$PATH:$TCBINARIES:$TCINCLUDES/bin"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CC=x86_64-linux-android-gcc' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export CXX=x86_64-linux-android-g++' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LD=x86_64-linux-android-ld' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -DDECLARE_TIMEZONE -Wall -I$TCINCLUDES/include -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+export CXXFLAGS="--sysroot=$TCSYSROOT -DANDROID -DANDROID_64 -Wall -I$TCINCLUDES/include -funroll-loops -fexceptions -O3 -fomit-frame-pointer -fPIE -D__ANDROID_API__=${COMPILE_SDK}"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export LDFLAGS="-L$TCSYSROOT/usr/lib64 -L$TCINCLUDES/lib64 -llog -fPIE -pie"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export GDB_CFLAGS="--sysroot=$TCSYSROOT -Wall -g -I$TCINCLUDES/include"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -35,7 +35,7 @@ export PKG_CONFIG_SYSROOT_DIR=$TCSYSROOT' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "==================building BOINC from $BOINC=========================="' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' make distclean' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '@@ -49,7 +49,9 @@ make stage' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Stripping Binaries"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd stage/usr/local/bin' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set +f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' x86_64-linux-android-strip *' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '+set -f' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' cd ../../../../' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo ' echo "Copy Assets"' >> /boinc_patches/build_boinc_sh.patch ) && \
	( echo '' >> /boinc_patches/build_boinc_sh.patch )
	
#TODO: give some mechanism to cancel sdk setup and libraries source dl if getboinc doesnt succeed (flag file?)
	
#P TODO: add patch for 32 bit to disable _FILE_OFFSET for boinc, boinc lib, and wrapper; this will make unified with stl=libc++ work
	
# patch to fix "clean" for libraries
RUN ( echo 'diff --git a/android/build_libraries_arm.sh b/android/build_libraries_arm.sh' > /boinc_patches/build_libraries_sh.patch ) && \
	( echo 'index 9e69ac4..aa68576 100755' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '--- a/android/build_libraries_arm.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+++ b/android/build_libraries_arm.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '@@ -37,8 +37,8 @@ if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' echo "==================building Libraries from $BOINC=========================="' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ./_autosetup' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo 'diff --git a/android/build_libraries_mips.sh b/android/build_libraries_mips.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo 'index 6a76558..760560c 100755' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '--- a/android/build_libraries_mips.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+++ b/android/build_libraries_mips.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '@@ -37,8 +37,8 @@ if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' echo "==================building Libraries from $BOINC=========================="' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ./_autosetup' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo 'diff --git a/android/build_libraries_x86.sh b/android/build_libraries_x86.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo 'index 2a2a295..c07a191 100755' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '--- a/android/build_libraries_x86.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+++ b/android/build_libraries_x86.sh' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '@@ -14,7 +14,7 @@ MAKECLEAN="yes"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' export BOINC=".." #BOINC source code' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' export ANDROID_TC="${ANDROID_TC:-$HOME/android-tc}"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-export ANDROIDTC="${ANDROID_TC_X86:-$ANDROID_TC/x86"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+export ANDROIDTC="${ANDROID_TC_X86:-$ANDROID_TC/x86}"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' export TCBINARIES="$ANDROIDTC/bin"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' export TCINCLUDES="$ANDROIDTC/i686-linux-android"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' export TCSYSROOT="$ANDROIDTC/sysroot"' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '@@ -37,8 +37,8 @@ if [ -n "$COMPILEBOINC" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' echo "==================building Libraries from $BOINC=========================="' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' cd $BOINC' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-if [ -n "$MAKECLEAN" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '-make clean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+if [ -n "$MAKECLEAN" -a -e Makefile ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo '+make distclean' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' fi' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' if [ -n "$CONFIGURE" ]; then' >> /boinc_patches/build_libraries_sh.patch ) && \
	( echo ' ./_autosetup' >> /boinc_patches/build_libraries_sh.patch )

#TODO: patch to fix "clean" for boinc wrapper build scripts
	
#start bash to keep alive
CMD ["/bin/bash", "-c", "tail -f /dev/null"]
