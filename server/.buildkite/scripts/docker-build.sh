#! /bin/bash

set -e

TOKEN=${GITHUB_TOKEN}
CHANNEL="${1:?Provide the channel this script is run on (stable, unstable)}"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

$DIR/kill-all-docker-containers.sh

if [ -z ${BUILDKITE_TAG} ]; then
    # Rolling number versioning for unstable
    LAST_GIT_TAG=$(git describe --tags $(git rev-list --tags --max-count=1))
    TAG_ELEMENTS=(${LAST_GIT_TAG//./ })
    NEXT_VERSION="${TAG_ELEMENTS[0]}.$((${TAG_ELEMENTS[1]} + 1))"
    LAST_DOCKER_TAG=$(curl -sS 'https://registry.hub.docker.com/v2/repositories/prismagraphql/prisma/tags/' | jq '."results"[]["name"]' --raw-output | grep -v latest | grep ${NEXT_VERSION}-beta- | head -n 1)

    echo "Last git tag: $LAST_GIT_TAG"
    echo "Next version: $NEXT_VERSION"
    echo "Last docker tag: $LAST_DOCKER_TAG"

    if [ -z LAST_DOCKER_TAG ]; then
        NEXT_DOCKER_TAG="$NEXT_VERSION-beta-1"
    else
        IFS=- read version betaStr rollingVersion <<< ${LAST_DOCKER_TAG}
        NEXT_DOCKER_TAG="$NEXT_VERSION-beta-$(($rollingVersion + 1))"

        echo "Rolling version: $rollingVersion"
        echo "Next docker tag: $NEXT_DOCKER_TAG"
    fi

    # Always release -beta as well
    ADDITIONALLY_RELEASE="$NEXT_VERSION-beta"
else
    # Stable release through tag. Tag both x.x and x.x.x.
    NEXT_VERSION=${BUILDKITE_TAG}
    NEXT_DOCKER_TAG=${BUILDKITE_TAG}
    IFS=. read major minor patch <<< ${BUILDKITE_TAG}

    # Check which image we additionally have to tag. Either x.x or x.x.x, depending which tag we pushed
    if [ -z $patch ]; then
        # We are releasing a x.x image, so tag x.x.x as well.
        ADDITIONALLY_RELEASE="$BUILDKITE_TAG.0"
    else
        # We already have x.x.x, so we need to retag the x.x image.
        ADDITIONALLY_RELEASE="$major.$minor"
    fi
fi

docker run -e "BRANCH=$BUILDKITE_BRANCH" -e "COMMIT_SHA=$BUILDKITE_COMMIT" -e "CLUSTER_VERSION=$NEXT_DOCKER_TAG" -v $(pwd):/root/build -w /root/build/server -v ~/.ivy2:/root/.ivy2 -v ~/.coursier:/root/.coursier  -v /var/run/docker.sock:/var/run/docker.sock graphcool/scala-sbt-docker sbt docker
docker images

for service in prisma prisma-prod;
do
  echo "Tagging prismagraphql/$service:latest image with $NEXT_DOCKER_TAG..."
  docker tag prismagraphql/${service}:latest prismagraphql/${service}:${NEXT_DOCKER_TAG}

  echo "Pushing prismagraphql/$service:$NEXT_DOCKER_TAG..."
  docker push prismagraphql/${service}:${NEXT_DOCKER_TAG}

  if [ ! -z "$ADDITIONALLY_RELEASE" ]; then
    echo "Additionally tagging and pushing prismagraphql/$service:latest image with $ADDITIONALLY_RELEASE..."
    docker tag prismagraphql/${service}:latest prismagraphql/${service}:${ADDITIONALLY_RELEASE}
    docker push prismagraphql/${service}:${ADDITIONALLY_RELEASE}
  fi
done

printf "
- trigger: \"prisma-cloud\"
  label: \":cloud: Trigger Prisma Cloud Tasks :cloud:\"
  async: true
  build:
    env:
        BUILD_TAG: \"${NEXT_DOCKER_TAG}\"
        CHANNEL: \"${CHANNEL}\"
" | buildkite-agent pipeline upload

