from core.utils.dialogue import Dialogue, Message


def test_dialogue_accepts_current_speaker_and_injects_once():
    dialogue = Dialogue()
    dialogue.put(Message(role="system", content="base {{current_time}}"))
    dialogue.put(Message(role="user", content="你好"))

    messages = dialogue.get_llm_dialogue_with_memory(
        None,
        {"speakers": ["spk1,张三,测试用户"]},
        "张三",
    )

    assert messages[0]["role"] == "system"
    assert "当前说话人：张三" in messages[0]["content"]
    assert "- 张三：测试用户" in messages[0]["content"]
    assert messages[1] == {"role": "user", "content": "你好"}
