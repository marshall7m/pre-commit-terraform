mkdir -p ./modules && mkdir -p ./tests
cat > ./modules/main.tf << EOF
output "foo" {
    value = "foo"
}
EOF

cat > ./tests/test_foo.tf << EOF
module "mut_foo" {
    source = "..//modules"
}
EOF
