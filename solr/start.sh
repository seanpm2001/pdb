#!/bin/sh

if [ -z "$JAVA_HOME" ]; then
	for dir in \
			/System/Library/Frameworks/JavaVM.framework/Versions/1.6*/Home \
			/System/Library/Frameworks/JavaVM.framework/Versions/1.5*/Home \
			/opt/jdk1.6* \
			/opt/jdk1.5* \
			/usr/java/jdk1.6* \
			/usr/java/jdk1.5* \
			/usr/lib/jvm/java-6-sun \
			/usr/lib/jvm/java-1.6*-sun \
			/usr/lib/jvm/java-1.5*-sun \
			; do
		if [ -x "$dir/bin/java" ]; then
			export JAVA_HOME="$dir"
			break;
		fi
	done
fi

LOGFILE=/dev/null
MYDIR=`dirname "$0"`
TOPDIR=`cd $MYDIR; pwd`

cd "$TOPDIR"
exec $JAVA_HOME/bin/java -Xms128m -Xmx512m -XX:MaxHeapFreeRatio=80 -XX:MinHeapFreeRatio=20 -Djava.net.preferIPv4Stack=true $SOLR_OPTS -jar $TOPDIR/start.jar >$LOGFILE 2>&1 &
