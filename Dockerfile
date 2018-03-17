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
# Gene Erik
# --

#
#  From this base-image / starting-point

FROM ubuntu:xenial

ENV BOINC_BRANCH ${BOINC_BRANCH:-master}
ENV OPENSSL_VERSION ${OPENSSL_VERSION:-1.0.2k}
ENV CURL_VERSION ${CURL_VERSION:-7.53.1}
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
		build-essential gcc-5 nasm automake libtool python pkg-config freeglut3-dev --yes --force-yes

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
		echo 'set -e'; \
		echo; \
		echo 'dirname "$(dirname "$(readlink -f "$(which javac || which java)")")"'; \
	} > /usr/local/bin/docker-java-home \
	&& chmod +x /usr/local/bin/docker-java-home

# do some fancy footwork to create a JAVA_HOME that's cross-architecture-safe
RUN ln -svT "/usr/lib/jvm/java-8-openjdk-$(dpkg --print-architecture)" /docker-java-home
ENV JAVA_HOME /docker-java-home

#This should probably be done dynamically and put in bashrc; TODO
ENV JAVA_VERSION 1.8.0_151
ENV JAVA_DEBIAN_VERSION 8u151-b12-0ubuntu0.16.04.2

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

#### NDK stuff

#RUN wget -q --output-document=android-ndk.zip https://dl.google.com/android/repository/android-ndk-r16b-linux-x86_64.zip && \
#	unzip android-ndk.zip && \
#	rm -f android-ndk.zip && \
#	mv android-ndk-r16b android-ndk-linux

#Gradle stuff
ENV GRADLE_HOME /opt/gradle
ENV GRADLE_VERSION 4.6

ARG GRADLE_DOWNLOAD_SHA256=98bd5fd2b30e070517e03c51cbb32beee3e2ee1a84003a5a5d748996d4b1b915
RUN set -o errexit -o nounset \
	&& echo "Downloading Gradle" \
	&& wget --no-verbose --output-document=gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
	\
	&& echo "Checking download hash" \
	&& echo "${GRADLE_DOWNLOAD_SHA256} *gradle.zip" | sha256sum --check - \
	\
	&& echo "Installing Gradle" \
	&& unzip gradle.zip \
	&& rm gradle.zip \
	&& mv "gradle-${GRADLE_VERSION}" "${GRADLE_HOME}/" \
	&& ln --symbolic "${GRADLE_HOME}/bin/gradle" /usr/bin/gradle
	
#Create script to clone the boinc repo
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getboinc.sh' ) && ( echo 'mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/BOINC/boinc.git && \
	cd boinc && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git pull --tags && \
	git checkout ${BOINC_BRANCH} && \
	git pull --all' >> /usr/local/bin/getboinc.sh ) && \
	chmod +x /usr/local/bin/getboinc.sh
	

#TODO: finish license auto agree script (updateandsdk.sh)
#Create script to get android ndk and sdk and create build tool chain
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getandtools.sh' ) && \
	( echo 'set -e' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export BUILD_TOOLS=`sed -n "s/.*buildToolsVersion\\s*\\"\\(.*\\)\\"/\\1/p" /opt/src/boinc/android/BOINC/app/build.gradle`' >> /usr/local/bin/getandtools.sh ) && \
    ( echo 'export COMPILE_SDK=`sed -n "s/.*compileSdkVersion\\s*\\(\\d*\\)/\\1/p" /opt/src/boinc/android/BOINC/app/build.gradle`' >> /usr/local/bin/getandtools.sh ) && \
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
	( echo '	yes | ${ANDROID_HOME}/tools/bin/sdkmanager --update' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	yes | ${ANDROID_HOME}/tools/bin/sdkmanager "ndk-bundle"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	yes | ${ANDROID_HOME}/tools/bin/sdkmanager "build-tools;${BUILD_TOOLS}"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	yes | ${ANDROID_HOME}/tools/bin/sdkmanager "platforms;android-${COMPILE_SDK}"' >> /usr/local/bin/getandtools.sh ) && \
	( echo '	yes | ${ANDROID_HOME}/tools/bin/sdkmanager "extras;android;m2repository" "extras;google;m2repository" "extras;google;google_play_services"' >> /usr/local/bin/getandtools.sh ) && \
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
	( echo 'fi' >> /usr/local/bin/getandtools.sh ) && \
	( echo 'export PATH=${PATH}:${ANDROID_HOME}/tools/bin:${ANDROID_HOME}/platform-tools:${PATH}:${ANDROID_HOME}/tools' >> /usr/local/bin/getandtools.sh ) && \
	chmod +x /usr/local/bin/getandtools.sh
	
#TODO: add all the needed tool chains for all targets: arm64 mips arm x86_64 mips64 x86 (or not; is part of build script)

# Add git clone to bashrc for root
RUN cp -r /etc/skel/. /root && \
	( echo "if [[ ! -e /opt/src/boinc ]];then /usr/local/bin/getboinc.sh; fi" >> /root/.bashrc ) && \
	( echo ". usr/local/bin/getandtools.sh" >> /root/.bashrc ) && \
	chmod +x /root/.bashrc
#TODO: add getandtools once we know it works

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

	
#Create boinc build script
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/buildboinc.sh' ) && \
	( echo 'set -e' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ ! -e ${ANDROID_TC}/${ANDROID_ARCH} ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	${ANDROID_NDK_HOME}/build/tools/make_standalone_toolchain.py --arch ${ANDROID_ARCH} --api ${COMPILE_SDK} --install-dir ${ANDROID_TC}/${ANDROID_ARCH}' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'cd /opt/src/boinc/android' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_androidtc_${ANDROID_ARCH}.sh 2>&1 | tee build_androidtc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_libraries_${ANDROID_ARCH}.sh 2>&1 | tee build_libraries_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_openssl_${ANDROID_ARCH}.sh 2>&1 | tee build_openssl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_curl_${ANDROID_ARCH}.sh 2>&1 | tee build_curl_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo './build_boinc_${ANDROID_ARCH}.sh 2>&1 | tee build_boinc_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'if [[ "${ANDROID_ARCH}" == "arm" || "${ANDROID_ARCH}" == "mips" || "${ANDROID_ARCH}" == "x86" ]]; then' >> /usr/local/bin/buildboinc.sh ) && \
	( echo '	./build_wrapper_${ANDROID_ARCH}.sh 2>&1 | tee build_wrapper_${ANDROID_ARCH}.log' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'fi' >> /usr/local/bin/buildboinc.sh ) && \
	( echo 'echo "successfully built boinc apk!!"' >> /usr/local/bin/buildboinc.sh ) && \
	chmod +x /usr/local/bin/buildboinc.sh

#TODO: build_boinc scripts are missing include of sysroot; must fix!
	
#start bash to keep alive
CMD ["/bin/bash", "-c", "tail -f /dev/null"]
