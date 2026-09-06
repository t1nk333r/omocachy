// Jenkins port of .github/workflows/lint.yml — runs on the docker-host agent.
pipeline {
  agent { label 'docker' }

  options {
    disableConcurrentBuilds(abortPrevious: true)
  }

  stages {
    stage('Bash syntax check') {
      steps {
        sh '''
          set -e
          for f in bin/*.sh bin/lib/*.sh tests/run.sh; do
            bash -n "$f"
            echo "OK: $f"
          done
        '''
      }
    }

    stage('ShellCheck') {
      steps {
        sh 'shellcheck --severity=error bin/*.sh bin/lib/*.sh tests/run.sh'
      }
    }

    // Fixture matrix + HOOKS merge + dry-run purity. Read-only: it runs the
    // installer only under --dry-run against tests/fixtures/* sysroots.
    stage('Test suite') {
      steps {
        sh 'tests/run.sh'
      }
    }
  }
}
