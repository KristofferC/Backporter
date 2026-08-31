# Creates a test repo, and then runs f() inside it
function with_test_repo(f::Function)
    original_dir = pwd()
    test_dir = mktempdir()
    try
        cd(test_dir)

        run(`git init --quiet --initial-branch=main`)
        run(`git config user.email "test@example.com"`)
        run(`git config user.name "Test User"`)
        run(`git config commit.gpgsign false`)

        commit_file("file.txt", "initial", "Initial commit")

        f()
    finally
        cd(original_dir)
        rm(test_dir; force=true, recursive=true)
    end
end

# Commits a single file and returns the commit sha
function commit_file(name, content, msg)
    write(name, content)
    run(`git add $name`)
    run(pipeline(`git commit --quiet -m $msg`; stdout=devnull))
    return readchomp(`git rev-parse HEAD`)
end

git_quiet(args...) = run(pipeline(`git $(collect(args))`; stdout=devnull, stderr=devnull))
