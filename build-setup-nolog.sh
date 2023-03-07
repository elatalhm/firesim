#!/usr/bin/env bash

# FireSim initial setup script.

# exit script if any command fails
set -e
set -o pipefail

FDIR=$(pwd)

IS_LIBRARY=false
SKIP_TOOLCHAIN=false
FORCE_FLAG=""
VERBOSE=false
VERBOSE_FLAG=""
TOOLCHAIN=riscv-tools
USE_PINNED_DEPS=true
SKIP_LIST=()

function usage
{
    echo "Usage: build-setup.sh [OPTIONS]"
    echo ""
    echo "Helper script to fully initialize repository that wraps other scripts."
    echo "By default it initializes/installs things in the following order:"
    echo "   1. Conda environment"
    echo "   2. FireSim submodules"
    echo "   3. All Chipyard Setup"
    echo "     4. Toolchain collateral (Spike, PK, tests, libgloss)"
    echo "     5. Chipyard Ctags"
    echo "     6. Chipyard pre-compile sources"
    echo "     7. FireMarshal"
    echo "     8. FireMarshal pre-compile default buildroot Linux sources"
    echo "   9. EC2 specific-setup"
    echo "   10. FireSim Ctags"
    echo "   11. FireSim pre-compile scala sources"
    echo ""
    echo "**See above for options to skip parts of the setup. Skipping parts of the setup is not guaranteed to be tested/working.**"
    echo ""
    echo "Options:"
    echo "   --help -h  : Display this message"
    echo "   --force -f : Skip all prompts and checks"
    echo "   --verbose -v : Verbose printout"
    echo "   --use-unpinned-deps -ud: Use unpinned conda environment"
    echo "   --skip -s : Skip step N in the list above. Use multiple times to skip multiple steps ('-s N -s M ...')."
    echo "   --library -l : if set, initializes submodules assuming FireSim is being used"
    echo "            as a library submodule. Implies skip for 1, 3-8"
    echo "   --ci -c : minimal steps needed for ci to run properly. Implies skip for 5-8, 10-11"
}

while [ "$1" != "" ];
do
   case "$1" in
        --library | -l)
            IS_LIBRARY=true;
            SKIP_TOOLCHAIN=true;
            ;;
        --ci | -c)
            SKIP_LIST+=(5 6 7 8 10 11)
            ;;
        --force | -f)
            FORCE_FLAG=$1;
            ;;
        --use-unpinned-deps | -ud)
            USE_PINNED_DEPS=false;
            ;;
        -h | --help)
            usage
            exit
            ;;
        --verbose | -v)
            VERBOSE_FLAG=$1
            set -x
            ;;
        --skip | -s)
            shift
            SKIP_LIST+=(${1})
            ;;
        --*) echo "ERROR: bad option $1"
            usage
            exit 1
            ;;
        *) echo "ERROR: bad argument $1"
            usage
            exit 2
            ;;
    esac
    shift
done


#######################################
# Return true if the arg is not
# found in the SKIP_LIST
#######################################
run_step() {
    local value=$1
    [[ ! " ${SKIP_LIST[*]} " =~ " ${value} " ]]
}

#######################################
# Save bash options. Must be called
# before a corresponding `restore_bash_options`.
#######################################
function save_bash_options
{
    OLDSTATE=$(set +o)
}

#######################################
# Restore bash options. Must be called
# after a corresponding `save_bash_options`.
#######################################
function restore_bash_options
{
    set +vx; eval "$OLDSTATE"
}

# before doing anything verify that you are on a release branch/tag
save_bash_options
set +e
tag=$(git describe --exact-match --tags)
tag_ret_code="$?"
restore_bash_options
if [ "$tag_ret_code" -ne 0 ]; then
    if [ -z "$FORCE_FLAG" ]; then
        read -p "WARNING: You are not on an official release of FireSim."$'\n'"Type \"y\" to continue if this is intended, otherwise see https://docs.fires.im/en/stable/Initial-Setup/Setting-up-your-Manager-Instance.html#setting-up-the-firesim-repo: " validate
        [[ "$validate" == [yY] ]] || exit 5
        echo "Setting up non-official FireSim release"
    fi
else
    echo "Setting up official FireSim release: $tag"
fi

if [ "$IS_LIBRARY" = true ]; then
    if [ -z "$RISCV" ]; then
        echo "ERROR: You must set the RISCV environment variable before running."
        exit 4
    else
        echo "Using existing RISCV toolchain at $RISCV"
    fi
fi

# Remove and backup the existing env.sh if it exists
# The existing of env.sh implies this script completely correctly
if [ -f env.sh ]; then
    mv -f env.sh env.sh.backup
fi


# This will be flushed out into a complete env.sh which will be written out
# upon completion.
env_string="# This file was generated by $0"

function env_append {
    env_string+=$(printf "\n$1")
}

# Initially, create a env.sh that suggests build.sh did not run correctly.
bad_env="${env_string}
echo \"ERROR: build-setup.sh did not execute correctly or was terminated prematurely.\"
echo \"Please review build-setup-log for more information.\"
return 1"
echo "$bad_env" > env.sh

env_append "export FIRESIM_ENV_SOURCED=1"

# Conda Setup
# Provide a sourceable snippet that can be used in subshells that may not have
# inhereted conda functions that would be brought in under a login shell that
# has run conda init (e.g., VSCode, CI)
read -r -d '\0' CONDA_ACTIVATE_PREAMBLE <<ENDCONDAACTIVATE
if ! type conda >& /dev/null; then
    echo "::ERROR:: you must have conda in your environment first"
    return 1  # do not want to exit here because this file is sourced
fi

# if we are sourcing this in a sub process that has conda in the PATH but not as a function, init it again
conda activate --help >& /dev/null || source $(conda info --base)/etc/profile.d/conda.sh
\0
ENDCONDAACTIVATE

if run_step "1"; then
    if [ "$IS_LIBRARY" = true ]; then
        # the chipyard conda environment should be installed already and be sufficient
        if [ -z "${CONDA_DEFAULT_ENV+x}" ]; then
            echo "ERROR: No conda environment detected. If using Chipyard, did you source 'env.sh'."
            exit 5
        fi
    else
        LOCKFILE="$RDIR/conda-reqs/conda-reqs.conda-lock.yml"
        if [ "$USE_PINNED_DEPS" = false ]; then
            # auto-gen the lockfile
            conda-lock -f "$RDIR/conda-reqs/firesim.yaml" -f "$RDIR/conda-reqs/ci-shared.yaml" --lockfile "$LOCKFILE"
        fi
        conda-lock install -p $FDIR/.conda-env $LOCKFILE
        source $FDIR/.conda-env/etc/profile.d/conda.sh
        conda activate $FDIR/.conda-env
        env_append "$CONDA_ACTIVATE_PREAMBLE"
        env_append "conda activate $FDIR/.conda-env"
    fi
fi

if run_step "2"; then
    git config submodule.target-design/chipyard.update none
    git submodule update --init --recursive #--jobs 8
fi

# Chipyard setup
if [ "$IS_LIBRARY" = false ]; then
    target_chipyard_dir="$FDIR/target-design/chipyard"

    if run_step "3"; then
        git config --unset submodule.target-design/chipyard.update
        git submodule update --init target-design/chipyard
        cd $FDIR/target-design/chipyard

        if run_step "4"; then
            SKIP_TOOLCHAIN_ARG="-s 3"
        fi
        if run_step "5"; then
            SKIP_CY_CTAGS="-s 4"
        fi
        if run_step "6"; then
            SKIP_CY_PRECOMPILE="-s 5"
        fi
        if run_step "7"; then
            SKIP_FM_SETUP="-s 8"
        fi
        if run_step "8"; then
            SKIP_FM_PRECOMPILE_BR="-s 9"
        fi
        # default to normal riscv-tools toolchain
        ./build-setup.sh --force -s 1 -s 6 -s 7 $SKIP_TOOLCHAIN_ARG $SKIP_CY_CTAGS $SKIP_CY_PRECOMPILE $SKIP_FM_SETUP $SKIP_FM_PRECOMPILE_BR

        # Deinitialize Chipyard's FireSim submodule so that fuzzy finders, IDEs,
        # etc., don't get confused by source duplication.
        git submodule deinit sims/firesim
        cd $FDIR

        env_append "export FIRESIM_STANDALONE=1"
        env_append "source $FDIR/scripts/fix-open-files.sh"
    fi
else
    target_chipyard_dir="$FDIR/../.."

    # Source CY env.sh in library-mode
    env_append "source $target_chipyard_dir/env.sh"
fi

# FireMarshal setup
if run_step "7"; then
    ln -sf $target_chipyard_dir/software/firemarshal $FDIR/sw/firesim-software
    env_append "export PATH=$FDIR/sw/firesim-software:\$PATH"

    # This checks if firemarshal has already been configured by someone. If
    # not, we will provide our own config. This must be checked before calling
    # init-submodules-no-riscv-tools.sh because that will configure
    # firemarshal.
    marshal_cfg="$FDIR/target-design/chipyard/software/firemarshal/marshal-config.yaml"
    if [ ! -f "$marshal_cfg" ]; then
        # Configure firemarshal to know where our firesim installation is.
        # If this is a fresh init of chipyard, we can safely overwrite the marshal
        # config, otherwise we have to assume the user might have changed it
      echo "firesim-dir: '../../../../'" > $marshal_cfg
    fi
fi

cd "$FDIR"

# commands to run only on EC2
# see if the instance info page exists. if not, we are not on ec2.
# this is one of the few methods that works without sudo
if run_step "9"; then
    if wget -T 1 -t 3 -O /dev/null http://169.254.169.254/; then

        (
            # ensure that we're using the system toolchain to build the kernel modules
            # newer gcc has --enable-default-pie and older kernels think the compiler
            # is broken unless you pass -fno-pie but then I was encountering a weird
            # error about string.h not being found
            export PATH=/usr/bin:$PATH

            cd "$FDIR/platforms/f1/aws-fpga/sdk/linux_kernel_drivers/xdma"
            make

            # the only ones missing are libguestfs-tools
            sudo yum install -y libguestfs-tools bc

            # Setup for using qcow2 images
            cd "$FDIR"
            ./scripts/install-nbd-kmod.sh
        )

        (
            if [[ "${CPPFLAGS:-zzz}" != "zzz" ]]; then
                # don't set it if it isn't already set but strip out -DNDEBUG because
                # the sdk software has assertion-only variable usage that will end up erroring
                # under NDEBUG with -Wall and -Werror
                export CPPFLAGS="${CPPFLAGS/-DNDEBUG/}"
            fi


            # Source {sdk,hdk}_setup.sh once on this machine to build aws libraries and
            # pull down some IP, so we don't have to waste time doing it each time on
            # worker instances
            AWSFPGA="$FDIR/platforms/f1/aws-fpga"
            cd "$AWSFPGA"
            bash -c "source ./sdk_setup.sh"
            bash -c "source ./hdk_setup.sh"
        )

    fi
fi

cd "$FDIR"
if run_step "10"; then
    set +e
    ./gen-tags.sh
    set -e
fi

if run_step "11"; then
    pushd "$FDIR/sim"
    (
        eval "$env_string" # source the current environment
        make firesim-main-classpath
        make target-classpath
    )
    popd
fi

read -r -d '\0' NDEBUG_CHECK <<ENDNDEBUG
# Ensure that we don't have -DNDEBUG anywhere in our environment

# check and fixup the known place where conda will put it
if [[ "$CPPFLAGS" == *"-DNDEBUG"* ]]; then
    echo "::INFO:: removing '-DNDEBUG' from CPPFLAGS as we prefer to leave assertions in place"
    export CPPFLAGS="${CPPFLAGS/-DNDEBUG/}"
fi

# check for any other occurances and warn the user
env | grep -v 'CONDA_.*_BACKUP' | grep -- -DNDEBUG && echo "::WARNING:: you still seem to have -DNDEBUG in your environment. This is known to cause problems."
true # ensure env.sh exits 0
\0
ENDNDEBUG
env_append "$NDEBUG_CHECK"

# Write out the generated env.sh indicating successful completion.
echo "$env_string" > env.sh

echo "Setup complete!"
echo "To generate simulator RTL and run metasimulation simulation, source env.sh"
echo "To use the manager to deploy builds/simulations on EC2, source sourceme-f1-manager.sh to setup your environment."
echo "To run builds/simulations manually on this machine, source sourceme-f1-full.sh to setup your environment."
echo "For more information, see docs at https://docs.fires.im/."
