#!/bin/bash

set -e
set -x

# defines the get_dep and show_installed_libraries functions
source build_tools/shared.sh

UNAMESTR=`uname`
CCACHE_LINKS_DIR="/tmp/ccache"

setup_ccache() {
    CCACHE_BIN=`which ccache || echo ""`
    if [[ "${CCACHE_BIN}" == "" ]]; then
        echo "ccache not found, skipping..."
    elif [[ -d "${CCACHE_LINKS_DIR}" ]]; then
        echo "ccache already configured, skipping..."
    else
        echo "Setting up ccache with CCACHE_DIR=${CCACHE_DIR}"
        mkdir ${CCACHE_LINKS_DIR}
        which ccache
        for name in gcc g++ cc c++ clang clang++ i686-linux-gnu-gcc i686-linux-gnu-c++ x86_64-linux-gnu-gcc x86_64-linux-gnu-c++ x86_64-apple-darwin13.4.0-clang x86_64-apple-darwin13.4.0-clang++; do
        ln -s ${CCACHE_BIN} "${CCACHE_LINKS_DIR}/${name}"
        done
        export PATH="${CCACHE_LINKS_DIR}:${PATH}"
        ccache -M 256M
    fi
}

pre_python_environment_install() {
    if [[ "$DISTRIB" == "ubuntu" ]]; then
        sudo apt-get update
        sudo apt-get install python3-scipy python3-matplotlib \
             libatlas3-base libatlas-base-dev python3-virtualenv ccache

    elif [[ "$DISTRIB" == "debian-32" ]]; then
        apt-get update
        apt-get install -y python3-dev python3-numpy python3-scipy \
                python3-matplotlib libatlas3-base libatlas-base-dev \
                python3-virtualenv python3-pandas ccache git

    elif [[ "$DISTRIB" == "conda-pypy3" ]]; then
        # need compilers
        apt-get -yq update
        apt-get -yq install build-essential
    fi

}

check_packages_dev_version() {
    for package in $@; do
        package_version=$(python -c "import $package; print($package.__version__)")
        if ! [[ $package_version =~ "dev" ]]; then
            echo "$package is not a development version: $package_version"
            exit 1
        fi
    done
}

python_environment_install_and_activate() {
    if [[ "$DISTRIB" == "conda"* ]]; then
        create_conda_environment_from_lock_file $VIRTUALENV $LOCK_FILE
        source activate $VIRTUALENV

    elif [[ "$DISTRIB" == "ubuntu" || "$DISTRIB" == "debian-32" ]]; then
        python3 -m virtualenv --system-site-packages --python=python3 $VIRTUALENV
        source $VIRTUALENV/bin/activate
        pip install -r "${LOCK_FILE}"

    elif [[ "$DISTRIB" == "pip-nogil" ]]; then
        python -m venv $VIRTUALENV
        source $VIRTUALENV/bin/activate
        pip install -r "${LOCK_FILE}"
    fi

    if [[ "$DISTRIB" == "conda-pip-scipy-dev" ]]; then
        echo "Installing development dependency wheels"
        dev_anaconda_url=https://pypi.anaconda.org/scientific-python-nightly-wheels/simple
        dev_packages="numpy scipy pandas"
        pip install --pre --upgrade --timeout=60 --extra-index $dev_anaconda_url $dev_packages

        check_packages_dev_version $dev_packages

        echo "Installing Cython from latest sources"
        pip install https://github.com/cython/cython/archive/master.zip
        echo "Installing joblib from latest sources"
        pip install https://github.com/joblib/joblib/archive/master.zip
        echo "Installing pillow from latest sources"
        pip install https://github.com/python-pillow/Pillow/archive/main.zip

    elif [[ "$DISTRIB" == "pip-nogil" ]]; then
        apt-get -yq update
        apt-get install -yq ccache

    fi
}

scikit_learn_install() {
    setup_ccache
    show_installed_libraries

    # Set parallelism to 3 to overlap IO bound tasks with CPU bound tasks on CI
    # workers with 2 cores when building the compiled extensions of scikit-learn.
    export SKLEARN_BUILD_PARALLEL=3

    if [[ "$UNAMESTR" == "Darwin" && "$SKLEARN_TEST_NO_OPENMP" == "true" ]]; then
        # Without openmp, we use the system clang. Here we use /usr/bin/ar
        # instead because llvm-ar errors
        export AR=/usr/bin/ar
        # Make sure omp.h is not present in the conda environment, so that
        # using an unprotected "cimport openmp" will make this build fail. At
        # the time of writing (2023-01-13), on OSX, blas (mkl or openblas)
        # brings in openmp so that you end up having the omp.h include inside
        # the conda environment.
        find $CONDA_PREFIX -name omp.h -delete -print
    fi

    if [[ "$UNAMESTR" == "Linux" ]]; then
        # FIXME: temporary fix to link against system libraries on linux
        # https://github.com/scikit-learn/scikit-learn/issues/20640
        export LDFLAGS="$LDFLAGS -Wl,--sysroot=/"
    fi

    if [[ "$BUILD_WITH_SETUPTOOLS" == "true" ]]; then
        python setup.py develop
    elif [[ "$PIP_BUILD_ISOLATION" == "true" ]]; then
        # Check that pip can automatically build scikit-learn with the build
        # dependencies specified in pyproject.toml using an isolated build
        # environment:
        pip install --verbose .
    else
        if [[ "$UNAMESTR" == "MINGW64"* ]]; then
           # Needed on Windows CI to compile with Visual Studio compiler
           # otherwise Meson detects a MINGW64 platform and use MINGW64
           # toolchain
           ADDITIONAL_PIP_OPTIONS='-Csetup-args=--vsenv'
        fi
        # Use the pre-installed build dependencies and build directly in the
        # current environment.
        pip install --verbose --no-build-isolation --editable . $ADDITIONAL_PIP_OPTIONS
    fi

    ccache -s || echo "ccache not installed, skipping ccache statistics"
}

main() {
    pre_python_environment_install
    python_environment_install_and_activate
    scikit_learn_install
}

main
