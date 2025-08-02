#!/bin/bash

# 获取当前账号的邮箱
current_email=$(gcloud config get-value account)
echo "当前账号的邮箱是: $current_email"

# 获取项目列表
project_list=$(gcloud projects list --format="value(projectId)")
echo "当前项目列表："
echo "$project_list"

# 循环解绑项目的结算账号
for project in $project_list; do
    echo "尝试解绑项目: $project"
    gcloud beta billing projects unlink $project --quiet || echo "解绑失败或项目未绑定: $project"
done

# 删除当前目录下的json文件
echo "正在删除当前目录下的json文件..."
rm -f *.json
echo "json文件删除完成"

# 项目前缀（邮箱前缀）
PROJECT_ID_PREFIX=${current_email%%@*}
echo "生成的项目前缀为: $PROJECT_ID_PREFIX"

# 后缀列表
SUFFIX_LIST=("a" "b" "c","d")

# 获取结算账号
billing_id=$(gcloud beta billing accounts list --format="value(name.basename())" | head -n 1)
if [ -z "$billing_id" ]; then
    echo "未找到结算账号"
    exit 1
else
    echo "结算账号: $billing_id"
fi

# 创建项目、绑定结算账号、启用Vertex AI、创建服务账号和密钥
for suffix in "${SUFFIX_LIST[@]}"; do
    PROJECT_ID="${PROJECT_ID_PREFIX}-${suffix}"
    echo "开始配置项目: $PROJECT_ID"

    # 创建项目
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"

    # 链接结算账号
    gcloud beta billing projects link "$PROJECT_ID" --billing-account="$billing_id"

    # 启用 Vertex AI API
    gcloud services enable aiplatform.googleapis.com --project="$PROJECT_ID"

    # 创建服务账号
    gcloud iam service-accounts create service-account --project="$PROJECT_ID"
    echo "等待服务账号生效..."
    sleep 20

    # 添加 IAM 权限（重试机制）
    max_retries=3
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:service-account@${PROJECT_ID}.iam.gserviceaccount.com" \
            --role="roles/aiplatform.serviceAgent"; then
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -eq $max_retries ]; then
                echo "添加 IAM 策略失败, 已重试 $max_retries 次"
                continue
            fi
            echo "重试添加 IAM 策略, 等待 10 秒..."
            sleep 10
        fi
    done

    # 创建服务账号密钥
    gcloud iam service-accounts keys create "pass-${PROJECT_ID}.json" \
        --iam-account="service-account@${PROJECT_ID}.iam.gserviceaccount.com" \
        --project="$PROJECT_ID"

    echo "项目 $PROJECT_ID 配置完成"
    echo "---------------------------"
done

echo "所有项目创建和配置完成"
