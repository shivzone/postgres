#-------------------------------------------------------------------------
#
# Makefile for src/bin/pg_rewind
#
# Portions Copyright (c) 2013-2016, PostgreSQL Global Development Group
#
# src/bin/pg_rewind/Makefile
#
#-------------------------------------------------------------------------

PGFILEDESC = "pg_rewind - synchronize a data directory with another one forked from"
PGAPPICON = win32

subdir = src/bin/pg_rewind
top_builddir = ../../..
include $(top_builddir)/src/Makefile.global

override CPPFLAGS := -I$(libpq_srcdir) -DFRONTEND $(CPPFLAGS)
LDFLAGS_INTERNAL += $(libpq_pgport)

CPPFLAGS += -lrdkafka
LDFLAGS_INTERNAL += -lrdkafka

OBJS	= pg_rewind.o parsexlog.o xlogreader.o datapagemap.o timeline.o \
	fetch.o file_ops.o copy_fetch.o libpq_fetch.o filemap.o logging.o \
	$(WIN32RES)

EXTRA_CLEAN = xlogreader.c

all: pg_rewind jk_kafka_consumer2

pg_rewind: $(OBJS) | submake-libpq submake-libpgport
	$(CC) $(CFLAGS) $^ $(LDFLAGS) $(LDFLAGS_EX) $(LIBS) -o $@$(X)

xlogreader.c: % : $(top_srcdir)/src/backend/access/transam/%
	rm -f $@ && $(LN_S) $< .

jk_kafka_consumer2: jk_kafka_consumer2.o $(OBJS) | submake-libpq submake-libpgport
	$(CC) $(CFLAGS) jk_kafka_consumer2.o $(OBJS) $(LDFLAGS) -I/usr/local/Cellar/librdkafka/1.1.0/include/ $(LDFLAGS_EX) $(LIBS) -o $@$(X)

install: all installdirs
	$(INSTALL_PROGRAM) pg_rewind$(X) '$(DESTDIR)$(bindir)/pg_rewind$(X)'
	$(INSTALL_PROGRAM) jk_kafka_consumer2$(X) '$(DESTDIR)$(bindir)/jk_kafka_consumer2$(X)'

installdirs:
	$(MKDIR_P) '$(DESTDIR)$(bindir)'

uninstall:
	rm -f '$(DESTDIR)$(bindir)/pg_rewind$(X)'
	rm -f '$(DESTDIR)$(bindir)/jk_kafka_consumer2$(X)'

clean distclean maintainer-clean:
	rm -f pg_rewind$(X) jk_kafka_consumer2$(X) $(OBJS) xlogreader.c
	rm -rf tmp_check

check:
	$(prove_check)

installcheck:
	$(prove_installcheck)

