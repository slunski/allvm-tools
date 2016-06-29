# Meta-make rules
.PHONY: libs clean install

# libs should be the default
libs::

CXXFLAGS += -fPIC # XXX: need this only for things in shared libraries

ifeq ($(DEBUG), 1)
CXXFLAGS += -DDEBUG
else
CXXFLAGS += -DNDEBUG
endif

CXXFLAGS += $(DEBUGFLAGS) $(OPTFLAGS)

CXXFLAGS += $(filter-out -O%,$(shell $(LLVMCONFIG) --cxxflags))
LDFLAGS += $(shell $(LLVMCONFIG) --ldflags --libs)

LAZY_CXXFLAGS = -MD -MP -MF .deps/$(@F).pp

################################################################################
# Rebuild if files change

Makefile: $(topsrcdir)/configure $(allmakefiles)
	cd $(topobjdir) && $(topsrcdir)/configure $(configflags)

%/Makefile: $(topsrcdir)/configure $(topsrcdir)/%/Makefile.in
	cd $(topobjdir) && $(topsrcdir)/configure $(configflags)

################################################################################
# Main rules for processing a makefile

_top := 1

# Recurse over all directories, accumulating the LIBRARIES and BINARIES
# variables, making sure that the relative path prefixes are set first.
define PrefixVariables
$(2) := $$(addprefix $(1),$$($(2)))

endef

define SaveVariable
_save_$(1) := $$($(1))
$(1) :=

endef

define ProcessVariable
$$(foreach file,$$($(1)), \
	$$(eval $$(call PrefixVariables,$$(relativedir)/,$$(file)_SOURCES)))
$(1) := $$(_save_$(1)) $$($(1))

endef

useful_vars := LIBRARIES RTLIBRARIES BINARIES
define IncludeDirectory
$(foreach var,$(useful_vars),$(call SaveVariable,$(var)))
DIRS :=
include $(1)/Makefile
$(foreach var,$(useful_vars),$(call ProcessVariable,$(var)))
$$(eval $$(foreach dir,$$(DIRS),$$(call IncludeDirectory,$$(relativedir)/$$(dir))))
endef

$(foreach dir,$(DIRS),$(eval $(call IncludeDirectory,$(dir))))

BUILT_LIBRARIES := $(patsubst %,prefix/lib/lib%.so,$(LIBRARIES))
BUILT_RTLIBRARIES := $(patsubst %,prefix/lib/lib%.a,$(RTLIBRARIES))
BUILT_BINARIES := $(patsubst %,prefix/bin/%,$(BINARIES))

libs:: $(BUILT_LIBRARIES) $(BUILT_RTLIBRARIES) $(BUILT_BINARIES)

define LinkLibrary
$(1)_objects := $(patsubst %.cpp,%.o,$($(1)_SOURCES))
$(1)_objects += $$(foreach l,$$($(1)_LIBRARIES),$$($$(l)_objects))
all_objects += $$($(1)_objects)
prefix/lib/lib$(1).so: $$($(1)_objects) prefix/lib/.mkdir.done
	$$(CXX) -shared -o $$@ $$(CXXFLAGS) $$(LDFLAGS) $$($(1)_objects)

clean::
	rm -rf prefix/lib/lib$(1).so $$($(1)_objects)
endef

define LinkRuntimeLibrary
$(1)_objects := $(patsubst %.cpp,%.o,$($(1)_SOURCES))
$(1)_objects += $$(foreach l,$$($(1)_LIBRARIES),$$($$(l)_objects))
all_objects += $$($(1)_objects)
prefix/lib/lib$(1).a: $$($(1)_objects) prefix/lib/.mkdir.done
	ar cr $$@ $$($(1)_objects)

clean::
	rm -rf prefix/lib/lib$(1).a $$($(1)_objects)
endef
llvmlibdir := $(shell $(LLVMCONFIG) --libdir)

define LinkBinary
$(1)_objects := $(patsubst %.cpp,%.o,$($(1)_SOURCES))
all_objects += $$($(1)_objects)
prefix/bin/$(1): $$($(1)_objects) prefix/bin/.mkdir.done
	$$(CXX) -o $$@ $$(CXXFLAGS) $$($(1)_objects) $$(LDFLAGS) $(shell $(LLVMCONFIG) --system-libs)

clean::
	rm -rf prefix/bin/$(1) $$($(1)_objects)
endef

clean::
	rm -rf .deps

$(foreach lib,$(LIBRARIES),$(eval $(call LinkLibrary,$(lib))))
$(foreach lib,$(RTLIBRARIES),$(eval $(call LinkRuntimeLibrary,$(lib))))
$(foreach bin,$(BINARIES),$(eval $(call LinkBinary,$(bin))))

all_objects := $(sort $(all_objects))

-include $(patsubst %,.deps/%.pp,$(notdir $(all_objects)))

################################################################################
# Auxiliary rules

$(all_objects): %.o: $(topsrcdir)/%.cpp .deps/.mkdir.done
	$(CXX) -o $@ -c $(CXXFLAGS) $(LAZY_CXXFLAGS) $(abspath $<)

%/.mkdir.done:
	@mkdir -p $*
	@touch $*/.mkdir.done

