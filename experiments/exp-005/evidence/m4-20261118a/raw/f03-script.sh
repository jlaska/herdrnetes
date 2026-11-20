set -u
X=$1; tag=$2; B=/workspace/.m4-barrier-$X
mkdir -p "$B"; touch "$B/ready-$tag"
while [ ! -e "$B/go" ]; do sleep 0.01; done
for i in 1 2 3 4; do
  ( python3 /opt/exp005/bin/request-repo "$X" "/tmp/src/$X.git" >/tmp/f03-$tag-$i.out 2>/tmp/f03-$tag-$i.err; echo $? >/tmp/f03-$tag-$i.rc ) &
done
wait
for i in 1 2 3 4; do echo "RESULT $tag $i rc=$(cat /tmp/f03-$tag-$i.rc) $(cat /tmp/f03-$tag-$i.out)"; done
echo "CLONING $tag $(cat /tmp/f03-$tag-*.err | grep -c 'cloning ')"
