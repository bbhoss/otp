include $(ERL_TOP)/make/target.mk
include $(ERL_TOP)/make/$(TARGET)/otp.mk

SUB_DIRECTORIES = src

include vsn.mk
VSN = $(QUIC_VSN)

SPECIAL_TARGETS =

include $(ERL_TOP)/make/otp_subdir.mk

.PHONY: info

include $(ERL_TOP)/make/app_targets.mk
