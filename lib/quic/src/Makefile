#
# %CopyrightBegin%
#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright Ericsson AB 2025. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# %CopyrightEnd%
#

include $(ERL_TOP)/make/target.mk
include $(ERL_TOP)/make/$(TARGET)/otp.mk

# ----------------------------------------------------
# Application version
# ----------------------------------------------------
include ../vsn.mk
VSN=$(QUIC_VSN)

# ----------------------------------------------------
# Release directory specification
# ----------------------------------------------------
RELSYSDIR = $(RELEASE_PATH)/lib/quic-$(VSN)

# ----------------------------------------------------
# Common Macros
# ----------------------------------------------------

MODULES= \
	gen_quic \
	quic \
	quic_app \
	quic_sup \
	quic_listener_sup \
	quic_connection_sup \
	quic_listener \
	quic_connection \
	quic_stream \
	quic_packet \
	quic_frame \
	quic_varint \
	quic_crypto \
	quic_tls \
	quic_transport_params \
	quic_recovery \
	quic_registry

HRL_FILES = quic.hrl

INTERNAL_HRL_FILES =

ERL_FILES = $(MODULES:%=%.erl)

TARGET_FILES= $(MODULES:%=$(EBIN)/%.$(EMULATOR)) $(APP_TARGET) $(APPUP_TARGET)

APP_FILE= quic.app
APP_SRC= $(APP_FILE).src
APP_TARGET= $(EBIN)/$(APP_FILE)

APPUP_FILE= quic.appup
APPUP_SRC= $(APPUP_FILE).src
APPUP_TARGET= $(EBIN)/$(APPUP_FILE)

# ----------------------------------------------------
# FLAGS
# ----------------------------------------------------

ERL_COMPILE_FLAGS += -I$(ERL_TOP)/lib/kernel/src \
	+warn_unused_vars \
	-DQUIC_VSN=\"$(VSN)\"

# ----------------------------------------------------
# Targets
# ----------------------------------------------------

$(TYPES): $(TARGET_FILES)

clean:
	rm -f $(TARGET_FILES)
	rm -f core

# ----------------------------------------------------
# Special Build Targets
# ----------------------------------------------------

$(APP_TARGET): $(APP_SRC) ../vsn.mk
	$(vsn_verbose)sed -e 's;%VSN%;$(VSN);' $< > $@

$(APPUP_TARGET): $(APPUP_SRC) ../vsn.mk
	$(vsn_verbose)sed -e 's;%VSN%;$(VSN);' $< > $@

# ----------------------------------------------------
# Release Target
# ----------------------------------------------------
include $(ERL_TOP)/make/otp_release_targets.mk

release_spec: opt
	$(INSTALL_DIR) "$(RELSYSDIR)/src"
	$(INSTALL_DATA) $(ERL_FILES) $(HRL_FILES) "$(RELSYSDIR)/src"
	$(INSTALL_DIR) "$(RELSYSDIR)/ebin"
	$(INSTALL_DATA) $(TARGET_FILES) "$(RELSYSDIR)/ebin"

release_docs_spec:
