require 'extend/ENV'

### Why `superenv`?
# 1) Only specify the environment we need (NO LDFLAGS for cmake)
# 2) Only apply compiler specific options when we are calling that compiler
# 3) Force all incpaths and libpaths into the cc instantiation (less bugs)
# 4) Cater toolchain usage to specific Xcode versions
# 5) Remove flags that we don't want or that will break builds
# 6) Simpler code
# 7) Simpler formula that *just work*
# 8) Build-system agnostic configuration of the tool-chain
# 9) No messing around trying to force build systems to use a particular cc

def superenv_bin
  @bin ||= (HOMEBREW_REPOSITORY/"Library/x").children.reject{|d| d.basename.to_s > MacOS::Xcode.version }.max
end

def superenv?
  superenv_bin.directory? and not ARGV.include? "--lame-env"
end

class << ENV
  def reset
    %w{CC CXX LD CPP OBJC MAKE
      CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS CPPFLAGS
      MACOS_DEPLOYMENT_TARGET SDKROOT
      CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CMAKE_FRAMEWORK_PATH
      HOMEBREW_OPTS HOMEBREW_DEP_PREFIXES
      MAKEFLAGS MAKEJOBS}.
      each{ |x| delete(x) }
    delete('CDPATH') # avoid make issues that depend on changing directories
    delete('GREP_OPTIONS') # can break CMake
    delete('CLICOLOR_FORCE') # autotools doesn't like this

    if MacOS.mountain_lion?
      # Fix issue with sed barfing on unicode characters on Mountain Lion
      delete('LC_ALL')
      ENV['LC_CTYPE'] = "C"
    end
  end

  def setup_build_environment
    reset
    ENV['CC'] = determine_cc
    ENV['CXX'] = determine_cxx
    ENV['LD'] = 'ld'
    ENV['CPP'] = 'cpp'
    ENV['MAKE'] = 'make'
    ENV['MAKEFLAGS'] ||= "-j#{Hardware.processor_count}"
    ENV['PATH'] = determine_path
    ENV['PKG_CONFIG_PATH'] = determine_pkg_config_path
    ENV['HOMEBREW_OPTS'] = 'b' if ARGV.build_bottle?
    ENV['HOMEBREW_MACOS'] = MACOS_VERSION.to_s
  end

  def universal_binary
    append 'HOMEBREW_OPTS', "u", ''
  end

  private

  def determine_cc
    if ARGV.include? '--use-gcc'
      "gcc"
    elsif ARGV.include? '--use-llvm'
      "llvm-gcc"
    elsif ARGV.include? '--use-clang'
      "clang"
    elsif ENV['HOMEBREW_USE_CLANG']
      opoo %{HOMEBREW_USE_CLANG is deprecated, use HOMEBREW_CC="clang" instead}
      "clang"
    elsif ENV['HOMEBREW_USE_LLVM']
      opoo %{HOMEBREW_USE_LLVM is deprecated, use HOMEBREW_CC="llvm" instead}
      "llvm-gcc"
    elsif ENV['HOMEBREW_USE_GCC']
      opoo %{HOMEBREW_USE_GCC is deprecated, use HOMEBREW_CC="gcc" instead}
      "gcc"
    elsif ENV['HOMEBREW_CC']
      if %w{clang gcc llvm}.include? ENV['HOMEBREW_CC']
        ENV['HOMEBREW_CC']
      else
        opoo "Invalid value for HOMEBREW_CC: #{ENV['HOMEBREW_CC']}"
        raise
      end
    else
      raise
    end
  rescue
    MacOS.default_compiler.to_s
  end

  def determine_cxx
    detcc = Proc.new do |cc|
      case cc.to_s
        when "clang" then "clang++"
        when "llvm-gcc" then "llvm-g++"
        when "gcc" then "gcc++"
      end
    end
    detcc.call(ENV['CC']) or detcc.call(MacOS.default_compiler) or "c++"
  end

  def determine_path
    paths = ORIGINAL_PATHS.dup
    paths.delete(HOMEBREW_PREFIX/:bin)
    paths.unshift("/opt/X11/bin")
    paths.unshift("#{HOMEBREW_PREFIX}/bin")
    if MacOS::Xcode.version >= "4.3" and not MacOS.xcode_clt_installed?
      paths.unshift("#{MacOS.xcode_43_developer_dir}/usr/bin")
      paths.unshift("#{MacOS.xcode_43_developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin")
    end
    paths.unshift(superenv_bin)
    paths.to_path_s
  end

  def determine_pkg_config_path
    paths = %w{/opt/X11/lib/pkgconfig /opt/X11/share/pkgconfig
               /usr/X11/lib/pkgconfig /usr/X11/share/pkgconfig}
    if MacOS.mountain_lion?
      # Mountain Lion no longer ships some .pcs; ensure we pick up our versions
      paths << "#{HOMEBREW_REPOSITORY}/Library/Homebrew/pkgconfig"
    end
    paths.to_path_s
  end

  public

### NO LONGER NECESSARY OR NO LONGER SUPPORTED
  def noop; end
  %w[m64 m32 gcc_4_0_1 fast O4 O3 O2 Os Og O1 libxml2 x11 minimal_optimization
    no_optimization enable_warnings fortran].each{|s| alias_method s, :noop }

### DEPRECATE THESE
  def compiler
    case ENV['CC']
      when "llvm-gcc" then :llvm
      when "gcc" then :gcc
    else
      :clang
    end
  end
  def deparallelize
    delete('MAKEFLAGS')
  end
  alias_method :j1, :deparallelize
  def gcc
    ENV['CC'] = "gcc"
    ENV['CXX'] = "g++"
  end
  def llvm
    ENV['CC'] = "llvm-gcc"
    ENV['CXX'] = "llvm-g++"
  end
  def clang
    ENV['CC'] = "clang"
    ENV['CXX'] = "clang++"
  end
  def make_jobs
    ENV['MAKEFLAGS'] =~ /-\w*j(\d)+/
    [$1.to_i, 1].max
  end

end if superenv?


if not superenv?
  ENV.extend(HomebrewEnvExtension)
  # we must do this or tools like pkg-config won't get found by configure scripts etc.
  ENV.prepend 'PATH', "#{HOMEBREW_PREFIX}/bin", ':' unless ORIGINAL_PATHS.include? HOMEBREW_PREFIX/'bin'
end


class Array
  def to_path_s
    map(&:to_s).select{|s| s and File.directory? s }.join(':')
  end
end

# new code because I don't really trust the Xcode code now having researched it more
module MacOS extend self
  def xcode_clt_installed?
    File.executable? "/usr/bin/clang" and File.executable? "/usr/bin/lldb"
  end

  def xcode_43_developer_dir
    @xcode_43_developer_dir ||=
      tst(ENV['DEVELOPER_DIR']) ||
      tst(`xcode-select -print-path 2>/dev/null`) ||
      tst("/Applications/Xcode.app/Contents/Developer") ||
      MacOS.mdfind("com.apple.dt.Xcode").find{|path| tst(path) }
    raise unless @xcode_43_developer_dir
    @xcode_43_developer_dir
  end

  private

  def tst prefix
    prefix = prefix.to_s.chomp
    xcrun = "#{prefix}/usr/bin/xcrun"
    prefix if xcrun != "/usr/bin/xcrun" and File.executable? xcrun
  end
end
