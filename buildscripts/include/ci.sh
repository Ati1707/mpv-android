#!/bin/bash -e

# go to buildscripts root folder
cd "$( dirname "${BASH_SOURCE[0]}" )/.."

. ./include/depinfo.sh # This provides ci_tarball and dep_mpv

# Define the architectures to build for
ARCHS_TO_BUILD=("armv7l" "arm64" "x86" "x86_64")

msg() {
	printf '==> %s\n' "$1"
}

fetch_prefix() {
	if [[ "$CACHE_MODE" == folder ]]; then
		local text=
		if [ -f "$CACHE_FOLDER/id.txt" ]; then
			text=$(cat "$CACHE_FOLDER/id.txt")
		else
			echo "Cache seems to be empty"
		fi
		printf 'Expecting "%s",\nfound     "%s".\n' "$ci_tarball" "$text"
		if [[ "$text" == "$ci_tarball" ]]; then
			msg "Extracting cached prefix from $CACHE_FOLDER/data.tgz"
			# Ensure prefix directory exists before extracting
			mkdir -p prefix
			if tar -xzf "$CACHE_FOLDER/data.tgz" -C prefix; then
				msg "Cached prefix extracted successfully."
				return 0
			else
				msg "Failed to extract cached prefix. Rebuilding."
				rm -rf prefix/* # Clean up potentially corrupted extraction
				return 1
			fi
		fi
	fi
	return 1
}

build_prefix() {
	msg "Building the prefix ($ci_tarball)..."

	msg "Fetching dependency sources (common for all archs)"
	# download-deps.sh should download source tarballs, not build them
	IN_CI=1 ./include/download-deps.sh

	# Build dependencies for each architecture
	for arch_val in "${ARCHS_TO_BUILD[@]}"; do
		msg "--- Building dependencies for $arch_val ---"
		# buildall.sh needs to correctly setup toolchain for $arch_val
		# and build dependencies listed in dep_mpv
		for x_dep in ${dep_mpv[@]}; do # dep_mpv is from depinfo.sh
			msg "Building dependency: $x_dep for $arch_val"
			# Assuming buildall.sh handles dependencies of $x_dep if -n is not passed
			./buildall.sh --arch "$arch_val" "$x_dep"
		done
		msg "--- Finished building dependencies for $arch_val ---"
	done


	if [[ "$CACHE_MODE" == folder && -w "$CACHE_FOLDER" ]]; then
		msg "Compressing the built prefix (all architectures)"
		# Ensure prefix directory exists before trying to compress from it
		if [ -d "prefix" ] && [ "$(ls -A prefix)" ]; then
			tar -cvzf "$CACHE_FOLDER/data.tgz" -C prefix .
			echo "$ci_tarball" >"$CACHE_FOLDER/id.txt"
			msg "Prefix compressed and identifier saved."
		else
			msg "Prefix directory is empty or does not exist. Skipping compression."
		fi
	fi
}

export WGET="wget --progress=bar:force"

if [ "$1" = "export" ]; then
	# export variable with unique cache identifier
	echo "CACHE_IDENTIFIER=$ci_tarball" # ci_tarball comes from depinfo.sh
	exit 0
elif [ "$1" = "install" ]; then
	# install system deps (done in GHA workflow)

	if [[ -n "$ANDROID_HOME" && -d "$ANDROID_HOME" ]]; then
		msg "Linking existing SDK"
		mkdir -p sdk
		ln -svf "$ANDROID_HOME" sdk/android-sdk-linux # Use -f to overwrite if exists
	fi

	msg "Fetching SDK + NDK (if not already linked/cached)"
	IN_CI=1 ./include/download-sdk.sh

	msg "Fetching mpv source"
	mkdir -p deps/mpv
	$WGET https://github.com/mpv-player/mpv/archive/master.tar.gz -O master.tgz
	tar -xzf master.tgz -C deps/mpv --strip-components=1
	rm master.tgz

	msg "Trying to fetch existing prefix (for all architectures)"
	mkdir -p prefix
	fetch_prefix || build_prefix
	exit 0
elif [ "$1" = "build" ]; then
	# This part is executed after 'install'
	# Native dependencies and their prefixes should already be built/cached by 'install'

	# Build mpv library for each architecture
	for arch_val in "${ARCHS_TO_BUILD[@]}"; do
		msg "Building mpv for $arch_val"
		# The -n flag prevents rebuilding dependencies of mpv, which should already be in prefix/
		# buildall.sh must correctly use the existing prefix for this $arch_val
		./buildall.sh -n --arch "$arch_val" mpv || {
			msg "ERROR: mpv build failed for $arch_val"
			# Assuming meson log path might involve arch or uses a common _build dir that gets configured per arch
			# The config.h check is a generic way to see if configure step succeeded
			[ ! -f deps/mpv/_build/config.h ] && [ -f deps/mpv/_build/meson-logs/meson-log.txt ] && cat deps/mpv/_build/meson-logs/meson-log.txt
			exit 1
		}
	done

	msg "Building mpv-android (APK)"
	# This will call buildall.sh with target mpv-android, which runs scripts/mpv-android.sh
	# scripts/mpv-android.sh should then find all the built .so files (for all archs)
	# from the prefix directories and build the universal release APK.
	# DONT_BUILD_RELEASE is not set, so scripts/mpv-android.sh should build release.
	./buildall.sh -n # target defaults to mpv-android

	exit 0
else
	echo "Unknown command: $1"
	echo "Usage: $0 [export|install|build]"
	exit 1
fi
