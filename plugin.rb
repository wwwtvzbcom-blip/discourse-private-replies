# name: discourse-private-replies
# about: Communiteq private replies plugin + [hide] reply-to-view
# version: 1.5.5
# authors: Communiteq + Grok
# url: https://www.communiteq.com/discoursehosting/kb/discourse-private-replies-plugin
# meta_topic_id: 146712

enabled_site_setting :private_replies_enabled

register_svg_icon "user-secret" if respond_to?(:register_svg_icon)

load File.expand_path('../lib/discourse_private_replies/engine.rb', __FILE__)

module ::DiscoursePrivateReplies
  def DiscoursePrivateReplies.can_see_all_posts?(user, topic)
    return false if user.nil? || user.anonymous?

    return true if user.staff?
    return true if topic && user.id == topic.user.id

    return true if SiteSetting.private_replies_participants_can_see_all && topic && Post.where(topic_id: topic.id, user_id: user.id).count > 0

    min_trust_level = SiteSetting.private_replies_min_trust_level_to_see_all
    if (min_trust_level >= 0) && (min_trust_level < 5)
      return true if user.has_trust_level?(TrustLevel[min_trust_level])
    end

    return true if (SiteSetting.private_replies_groups_can_see_all.split('|').map(&:to_i) & user.groups.pluck(:id)).count > 0

    if SiteSetting.private_replies_topic_starter_primary_group_can_see_all && topic
      if topic.user && !topic.user.anonymous? && topic.user.primary_group_id
        groupids = Group.find(topic.user.primary_group_id).users.pluck(:id)
        return true if groupids.include? user.id
      end
    end

    false
  end

  def DiscoursePrivateReplies.can_see_post_if_author_among(user, topic)
    userids = []
    Group.where("id in (?)", SiteSetting.private_replies_see_all_from_groups.split('|')).each do |g|
      userids += g.users.pluck(:id)
    end
    userids = userids + [ topic.user.id ] if topic
    userids = userids + [ user.id ] if user && !user.anonymous?
    userids.uniq
  end
end

after_initialize do

  # =========================================
  # [hide] 回复后可见功能（独立于私密回复）
  # =========================================
  class ::PrettyText
    class << self
      alias_method :original_cook, :cook

      def cook(raw, opts = {})
        result = original_cook(raw, opts)

        # 处理 [hide] 标签
        result.gsub!(%r{<p>\[hide\](.*?)\[/hide\]</p>}m) do
          hidden_content = $1.strip
          current_user = opts[:user] || opts[:guardian]&.user
          can_see = false

          if current_user && opts[:topic_id]
            topic = Topic.find_by(id: opts[:topic_id])
            if topic
              can_see = current_user.staff? ||
                        current_user.id == topic.user_id ||
                        Post.where(topic_id: topic.id, user_id: current_user.id).exists?
            end
          end

          if can_see
            <<~HTML
              <div class="hide-content-unlocked" style="background:#e8f5e8;padding:15px;border-left:5px solid #28a745;margin:15px 0;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,0.1);font-size:15px;">
                <div style="display:flex;align-items:center;margin-bottom:8px;">
                  <span style="font-size:22px;margin-right:10px;">Unlocked</span>
                  <strong style="color:#155724;">已解锁隐藏内容</strong>
                </div>
                <div style="line-height:1.6;">#{hidden_content.gsub(/<br\s*\/?>/i, "\n").strip}</div>
              </div>
            HTML
          else
            <<~HTML
              <div class="hide-content-locked" style="background:#fff3cd;padding:15px;border-left:5px solid #ffc107;margin:15px 0;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,0.1);">
                <div style="display:flex;align-items:center;">
                  <span style="font-size:22px;margin-right:10px;">Locked</span>
                  <div>
                    <strong style="color:#856404;">回复后可见</strong><br>
                    <small style="color:#856404;">回复本主题后即可查看隐藏内容</small>
                  </div>
                </div>
              </div>
            HTML
          end
        end

        result
      end
    end
  end

  # =========================================
  # 原有私密回复功能（保持不变）
  # =========================================

  module ::PostGuardian
    alias_method :org_can_see_post?, :can_see_post?

    def can_see_post?(post)
      return true if is_admin?
      allowed = org_can_see_post?(post)
      return false unless allowed

      if SiteSetting.private_replies_enabled && post.topic&.custom_fields['private_replies']
        return true if DiscoursePrivateReplies.can_see_all_posts?(@user, post.topic)
        userids = DiscoursePrivateReplies.can_see_post_if_author_among(@user, post.topic)
        return false unless userids.include? post.user.id
      end

      true
    end
  end

  module PatchTopicView
    def participants
      result = super
      if SiteSetting.private_replies_enabled && @topic&.custom_fields['private_replies']
        if !@user || !DiscoursePrivateReplies.can_see_all_posts?(@user, @topic)
          userids = DiscoursePrivateReplies.can_see_post_if_author_among(@user, @topic)
          result.select! { |key, _| userids.include?(key) }
        end
      end
      result
    end

    def unfiltered_posts
      result = super
      if SiteSetting.private_replies_enabled && @topic&.custom_fields['private_replies']
        if !@user || !DiscoursePrivateReplies.can_see_all_posts?(@user, @topic)
          userids = DiscoursePrivateReplies.can_see_post_if_author_among(@user, @topic)
          result = result.where('(posts.post_number = 1 OR posts.user_id IN (?))', userids)
        end
      end
      result
    end

    def filter_posts_by_ids(post_ids)
      @posts = super(post_ids)
      if SiteSetting.private_replies_enabled && @topic&.custom_fields['private_replies']
        if !@user || !DiscoursePrivateReplies.can_see_all_posts?(@user, @topic)
          userids = DiscoursePrivateReplies.can_see_post_if_author_among(@user, @topic)
          @posts = @posts.where('(posts.post_number = 1 OR posts.user_id IN (?))', userids)
        end
      end
      @posts
    end
  end

  module PatchTopicViewDetailsSerializer
    def last_poster
      if SiteSetting.private_replies_enabled && object.topic&.custom_fields['private_replies']
        if !scope.user || !DiscoursePrivateReplies.can_see_all_posts?(scope.user, object.topic)
          userids = DiscoursePrivateReplies.can_see_post_if_author_among(scope.user, object.topic)
          return object.topic.user unless !userids.include? object.topic.last_poster
        end
      end
      object.topic.last_poster
    end
  end

  module PatchTopicPostersSummary
    def initialize(topic, options = {})
      super
      if SiteSetting.private_replies_enabled && @topic&.custom_fields['private_replies']
        @filter_userids = DiscoursePrivateReplies.can_see_post_if_author_among(@user, @topic)
      else
        @filter_userids = nil
      end
    end

    def summary
      result = super
      result.select! { |v| @filter_userids.include?(v.user.id) } if @filter_userids
      result
    end
  end

  module PatchSearch
    def execute(readonly_mode: @readonly_mode)
      super

      if SiteSetting.private_replies_enabled && !DiscoursePrivateReplies.can_see_all_posts?(@guardian.user, nil)
        userids = DiscoursePrivateReplies.can_see_post_if_author_among(@guardian.user, nil)
        protected_topics = TopicCustomField.where(name: 'private_replies', value: true).pluck(:topic_id)

        @results.posts.delete_if do |post|
          next false unless protected_topics.include? post.topic_id
          next false if userids.include? post.user_id
          next false if post.user_id == post.topic.user_id
          next false if @guardian.user.id == post.topic.user_id
          true
        end
      end

      @results
    end
  end

  class ::UserAction
    module PrivateRepliesApplyCommonFilters
      def apply_common_filters(builder, user_id, guardian, ignore_private_messages = false)
        if SiteSetting.private_replies_enabled && !DiscoursePrivateReplies.can_see_all_posts?(guardian.user, nil)
          userids = DiscoursePrivateReplies.can_see_post_if_author_among(guardian.user, nil)
          userid_list = userids.join(',')
          protected_topic_list = TopicCustomField.where(name: 'private_replies', value: true).pluck(:topic_id).join(',')

          unless protected_topic_list.empty?
            builder.where("( (a.target_topic_id NOT IN (#{protected_topic_list})) OR (a.acting_user_id = t.user_id) OR (a.acting_user_id IN (#{userid_list})) )")
          end
        end
        super(builder, user_id, guardian, ignore_private_messages)
      end
    end
    singleton_class.prepend PrivateRepliesApplyCommonFilters
  end

  class ::Topic
    class << self
      alias_method :original_for_digest_private_replies, :for_digest

      def for_digest(user, since, opts = nil)
        topics = original_for_digest_private_replies(user, since, opts)
        if SiteSetting.private_replies_enabled && !DiscoursePrivateReplies.can_see_all_posts?(user, nil) && topics.to_sql.include?('INNER JOIN "posts"')
          userid_list = DiscoursePrivateReplies.can_see_post_if_author_among(user, nil).join(',')
          protected_topic_list = TopicCustomField.where(name: 'private_replies', value: true).pluck(:topic_id).join(',')
          topics = topics.where("(topics.id NOT IN (#{protected_topic_list}) OR posts.post_number = 1 OR topics.user_id = #{user.id} OR posts.user_id IN (#{userid_list}))")
        end
        topics
      end
    end
  end

  class ::TopicView
    prepend PatchTopicView
  end

  class ::TopicPostersSummary
    prepend PatchTopicPostersSummary
  end

  class ::TopicViewDetailsSerializer
    prepend PatchTopicViewDetailsSerializer
  end

  class ::Search
    prepend PatchSearch
  end

  Topic.register_custom_field_type('private_replies', :boolean)
  add_to_serializer(:topic_view, :private_replies) { !!(object.topic.custom_fields['private_replies']) }
  add_to_serializer(:topic_view, :private_replies_limited, include_condition: -> { object.topic.custom_fields['private_replies'] }) do
    !(DiscoursePrivateReplies.can_see_all_posts?(scope&.user, object.topic))
  end

  Discourse::Application.routes.append do
    mount ::DiscoursePrivateReplies::Engine, at: "/private_replies"
  end

  DiscourseEvent.on(:topic_created) do |topic|
    if SiteSetting.private_replies_enabled
      if (SiteSetting.private_replies_on_selected_categories_only == false) || (topic&.category&.custom_fields&.dig('private_replies_enabled'))
        if topic&.category&.custom_fields&.dig('private_replies_default_enabled')
          topic.custom_fields['private_replies'] = true
          topic.save_custom_fields
        end
      end
    end
  end

  Site.preloaded_category_custom_fields << 'private_replies_default_enabled'
  Site.preloaded_category_custom_fields << 'private_replies_enabled'
  add_preloaded_topic_list_custom_field("private_replies")
end
